#!/bin/bash

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/boutique-datasets}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXPORT_DIR="$OUTPUT_DIR/export_$TIMESTAMP"
TIME_RANGE_HOURS="${TIME_RANGE_HOURS:-1}"
END_TIME=$(date +%s)
START_TIME=$((END_TIME - TIME_RANGE_HOURS * 3600))
LOG_FILE="$OUTPUT_DIR/export.log"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_TIMEOUT="${CURL_TIMEOUT:-30}"
CURL_BASE_ARGS=(--connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_TIMEOUT}")

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

curl_or_warn() {
    local label="$1"
    shift
    if ! curl "$@"; then
        log "WARN: curl failed for ${label}"
        return 1
    fi
    return 0
}

setup_kubectl() {
    if kubectl get nodes >/dev/null 2>&1; then
        KUBECTL_CMD="kubectl"
    elif sudo kubectl get nodes >/dev/null 2>&1; then
        KUBECTL_CMD="sudo kubectl"
    elif minikube kubectl -- get nodes >/dev/null 2>&1; then
        KUBECTL_CMD="minikube kubectl --"
    else
        log "ERROR: Cannot access Kubernetes cluster"
        exit 1
    fi
    log "kubectl command found: $KUBECTL_CMD"
}

setup_urls() {
    if minikube status >/dev/null 2>&1; then
        MINIKUBE_IP=$(minikube ip 2>/dev/null)
        if [ -n "$MINIKUBE_IP" ]; then
            PROMETHEUS_URL="http://$MINIKUBE_IP:30090"
            LOKI_URL="http://$MINIKUBE_IP:30094"
        else
            PROMETHEUS_URL="http://localhost:30090"
            LOKI_URL="http://localhost:30094"
        fi
    else
        PROMETHEUS_URL="http://localhost:30090"
        LOKI_URL="http://localhost:30094"
    fi
}

verify_connectivity() {
    log "Checking Prometheus at $PROMETHEUS_URL"
    if curl_or_warn "prometheus status" "${CURL_BASE_ARGS[@]}" -s -f "$PROMETHEUS_URL/api/v1/status/config" >/dev/null 2>&1; then
        PROMETHEUS_ACCESSIBLE=true
    else
        log "Cannot connect to Prometheus at $PROMETHEUS_URL"
        PROMETHEUS_ACCESSIBLE=false
    fi
    
    log "Checking Loki at $LOKI_URL"
    if curl_or_warn "loki ready" "${CURL_BASE_ARGS[@]}" -s -f "$LOKI_URL/ready" >/dev/null 2>&1; then
        LOKI_ACCESSIBLE=true
    else
        log "Cannot connect to Loki at $LOKI_URL"
        LOKI_ACCESSIBLE=false
    fi
    
    if [ "$PROMETHEUS_ACCESSIBLE" = "false" ] && [ "$LOKI_ACCESSIBLE" = "false" ]; then
        log "ERROR: Cannot connect to Prometheus or Loki"
        exit 1
    fi
}

export_metadata() {
    log "Exporting metadata"
    $KUBECTL_CMD get pods -o json > "$EXPORT_DIR/metadata/boutique-pods.json"
    $KUBECTL_CMD get svc -o json > "$EXPORT_DIR/metadata/boutique-services.json"
    
    BOUTIQUE_SERVICES=$($KUBECTL_CMD get pods -o jsonpath='{.items[*].metadata.labels.app}' | tr ' ' '\n' | sort -u | grep -v '^$')
    echo "$BOUTIQUE_SERVICES" > "$EXPORT_DIR/metadata/service-list.txt"
    
    cat > "$EXPORT_DIR/metadata/export-info.json" <<EOF
{
  "export_timestamp": "$TIMESTAMP",
  "start_time": $START_TIME,
  "end_time": $END_TIME,
  "time_range_hours": $TIME_RANGE_HOURS,
  "prometheus_url": "$PROMETHEUS_URL",
  "loki_url": "$LOKI_URL",
  "boutique_services": $(echo "$BOUTIQUE_SERVICES" | jq -R -s -c 'split("\n") | map(select(length > 0))')
}
EOF
}

export_kubernetes_events() {
    log "Exporting Kubernetes events"
    
    $KUBECTL_CMD get events --all-namespaces \
        --sort-by='.lastTimestamp' \
        -o json > "$EXPORT_DIR/events/k8s-events.json"
    
    $KUBECTL_CMD get events --all-namespaces \
        --sort-by='.lastTimestamp' | \
        awk 'NR==1 || $1 != "NAMESPACE"' > "$EXPORT_DIR/events/k8s-events.txt"
    
    $KUBECTL_CMD get events --all-namespaces \
        --sort-by='.lastTimestamp' \
        -o json | jq -r '
        .items[] | 
        [
            .lastTimestamp // .eventTime,
            .involvedObject.namespace,
            .involvedObject.kind,
            .involvedObject.name,
            .reason,
            .type,
            .message,
            .count
        ] | @csv
    ' > "$EXPORT_DIR/events/k8s-events.csv"
    
    if [ -s "$EXPORT_DIR/events/k8s-events.csv" ]; then
        sed -i '1i"timestamp","namespace","kind","name","reason","type","message","count"' "$EXPORT_DIR/events/k8s-events.csv"
        
        EVENT_COUNT=$(wc -l < "$EXPORT_DIR/events/k8s-events.csv")
        log "Exported $((EVENT_COUNT - 1)) Kubernetes events"
        
        grep -i "error\|failed\|kill\|evict\|backoff\|unhealthy" "$EXPORT_DIR/events/k8s-events.csv" > "$EXPORT_DIR/events/error-events.csv" 2>/dev/null || true
        if [ -s "$EXPORT_DIR/events/error-events.csv" ]; then
            sed -i '1i"timestamp","namespace","kind","name","reason","type","message","count"' "$EXPORT_DIR/events/error-events.csv"
            ERROR_COUNT=$(wc -l < "$EXPORT_DIR/events/error-events.csv")
            log "Found $((ERROR_COUNT - 1)) error/failure events"
        else
            rm -f "$EXPORT_DIR/events/error-events.csv"
        fi
    else
        rm -f "$EXPORT_DIR/events/k8s-events.csv"
    fi
}

export_chaos_timeline() {
    log "Exporting chaos experiment timeline"
    
    $KUBECTL_CMD get podchaos,networkchaos,stresschaos,iochaos,timechaos \
        --all-namespaces -o json > "$EXPORT_DIR/chaos/chaos-experiments.json" 2>/dev/null || echo '{"items":[]}' > "$EXPORT_DIR/chaos/chaos-experiments.json"
    
    $KUBECTL_CMD get schedule --all-namespaces -o json > "$EXPORT_DIR/chaos/chaos-schedules.json" 2>/dev/null || echo '{"items":[]}' > "$EXPORT_DIR/chaos/chaos-schedules.json"
    
    if [ -f "$EXPORT_DIR/chaos/chaos-experiments.json" ]; then
        cat "$EXPORT_DIR/chaos/chaos-experiments.json" | jq -r '
            .items[] | 
            [
                .metadata.creationTimestamp,
                .kind,
                .metadata.name,
                .metadata.namespace,
                .spec.action // "unknown",
                .spec.mode // "unknown",
                .spec.duration // "unknown",
                (.spec.selector.labelSelectors | to_entries | map("\(.key)=\(.value)") | join(";")) // "unknown"
            ] | @csv
        ' > "$EXPORT_DIR/chaos/chaos-timeline.csv" 2>/dev/null
        
        if [ -s "$EXPORT_DIR/chaos/chaos-timeline.csv" ]; then
            sed -i '1i"created_at","type","name","namespace","action","mode","duration","target_selector"' "$EXPORT_DIR/chaos/chaos-timeline.csv"
            CHAOS_COUNT=$(wc -l < "$EXPORT_DIR/chaos/chaos-timeline.csv")
            log "Exported $((CHAOS_COUNT - 1)) chaos experiments"
        else
            rm -f "$EXPORT_DIR/chaos/chaos-timeline.csv"
        fi
    fi
}

export_service_dependencies() {
    log "Exporting service dependencies"
    
    $KUBECTL_CMD get svc -o json | jq -r '
        .items[] | 
        [
            .metadata.name,
            .spec.selector.app // "none",
            .spec.type,
            (.spec.ports | map("\(.port):\(.targetPort)") | join(";"))
        ] | @csv
    ' > "$EXPORT_DIR/dependencies/services.csv"

    if [ -s "$EXPORT_DIR/dependencies/services.csv" ]; then
        sed -i '1i"service_name","app_selector","type","ports"' "$EXPORT_DIR/dependencies/services.csv"
    else
	    echo "$EXPORT_DIR/dependencies/services.csv does not exist or is empty."
    fi
    
    if [ "$PROMETHEUS_ACCESSIBLE" = "true" ]; then
        curl_or_warn "prometheus network connections" "${CURL_BASE_ARGS[@]}" -G -s "$PROMETHEUS_URL/api/v1/query_range" \
            --data-urlencode 'query=rate(container_network_transmit_bytes_total{namespace="default"}[5m])' \
            --data-urlencode "start=$START_TIME" \
            --data-urlencode "end=$END_TIME" \
            --data-urlencode "step=60s" \
            -o "$EXPORT_DIR/raw/network-connections.json" 2>/dev/null

        if [ -f "$EXPORT_DIR/raw/network-connections.json" ]; then
            cat "$EXPORT_DIR/raw/network-connections.json" | jq -r '
                .data.result[] | 
                .metric as $labels | 
                [
                    ($labels.pod // "unknown"),
                    ($labels.namespace // "default")
                ] | @csv
            ' | sort -u > "$EXPORT_DIR/dependencies/active-pods.csv" 2>/dev/null
            
            if [ -s "$EXPORT_DIR/dependencies/active-pods.csv" ]; then
                sed -i '1i"pod","namespace"' "$EXPORT_DIR/dependencies/active-pods.csv"
            fi
        fi
    else
	    echo "Prometheus is not accessible."
    fi
}

parse_log_errors() {
    if [ "$LOKI_ACCESSIBLE" != "true" ]; then
        return
    fi
    
    log "Parsing log errors and patterns"
    
    if [ -f "$EXPORT_DIR/logs/all-logs.csv" ]; then
        grep -iE "error|exception|fatal|panic|fail|timeout|refused|unavailable" "$EXPORT_DIR/logs/all-logs.csv" > "$EXPORT_DIR/analysis/error-logs.csv" 2>/dev/null || true
        
        if [ -s "$EXPORT_DIR/analysis/error-logs.csv" ]; then
            sed -i '1i"timestamp_ns","app","namespace","log_message"' "$EXPORT_DIR/analysis/error-logs.csv"
            ERROR_LOG_COUNT=$(wc -l < "$EXPORT_DIR/analysis/error-logs.csv")
            log "Found $((ERROR_LOG_COUNT - 1)) error logs"
            
            tail -n +2 "$EXPORT_DIR/analysis/error-logs.csv" | cut -d',' -f4 | \
                grep -oE "(error|exception|fatal|panic|fail|timeout|refused|unavailable)[^,]*" | \
                sort | uniq -c | sort -rn > "$EXPORT_DIR/analysis/error-patterns.txt"
        else
            rm -f "$EXPORT_DIR/analysis/error-logs.csv"
        fi
        
        tail -n +2 "$EXPORT_DIR/logs/all-logs.csv" | cut -d',' -f2 | sort | uniq -c | \
            awk '{print $2","$1}' > "$EXPORT_DIR/analysis/logs-per-service.csv"
        sed -i '1i"service","log_count"' "$EXPORT_DIR/analysis/logs-per-service.csv"
    fi
}

export_loki_logs() {
    if [ "$LOKI_ACCESSIBLE" != "true" ]; then
        return
    fi
    log "Exporting Loki logs"
    
    SERVICES=$($KUBECTL_CMD get pods -o jsonpath='{.items[*].metadata.labels.app}' | tr ' ' '\n' | sort -u | grep -v '^$')
    
    for service in $SERVICES; do
        log "Fetching Loki logs for ${service}"
        curl_or_warn "loki logs ${service}" "${CURL_BASE_ARGS[@]}" -G -s "$LOKI_URL/loki/api/v1/query_range" \
            --data-urlencode "query={app=\"$service\"}" \
            --data-urlencode "start=${START_TIME}000000000" \
            --data-urlencode "end=${END_TIME}000000000" \
            --data-urlencode "limit=5000" \
            -o "$EXPORT_DIR/raw/loki-${service}.json" 2>/dev/null
        
        if [ -f "$EXPORT_DIR/raw/loki-${service}.json" ]; then
            HAS_DATA=$(cat "$EXPORT_DIR/raw/loki-${service}.json" | jq -r '.data.result | length' 2>/dev/null)
            
            if [ "$HAS_DATA" != "0" ] && [ "$HAS_DATA" != "null" ] && [ -n "$HAS_DATA" ]; then
                cat "$EXPORT_DIR/raw/loki-${service}.json" | jq -r '
                    .data.result[] | .values[] | [.[0], .[1]] | @csv
                ' > "$EXPORT_DIR/logs/${service}-logs.csv" 2>/dev/null
                
                if [ -s "$EXPORT_DIR/logs/${service}-logs.csv" ]; then
                    sed -i '1i"timestamp_ns","log_message"' "$EXPORT_DIR/logs/${service}-logs.csv"
                else
                    rm -f "$EXPORT_DIR/logs/${service}-logs.csv"
                fi
            fi
            
            if [ "$HAS_DATA" = "0" ] || [ "$HAS_DATA" = "null" ]; then
                rm -f "$EXPORT_DIR/raw/loki-${service}.json"
            fi
        fi
    done
    
    log "Fetching Loki logs for all services"
    curl_or_warn "loki logs all services" "${CURL_BASE_ARGS[@]}" -G -s "$LOKI_URL/loki/api/v1/query_range" \
        --data-urlencode 'query={app=~".+"}' \
        --data-urlencode "start=${START_TIME}000000000" \
        --data-urlencode "end=${END_TIME}000000000" \
        --data-urlencode "limit=10000" \
        -o "$EXPORT_DIR/raw/loki-all.json" 2>/dev/null
    
    if [ -f "$EXPORT_DIR/raw/loki-all.json" ]; then
        HAS_DATA=$(cat "$EXPORT_DIR/raw/loki-all.json" | jq -r '.data.result | length' 2>/dev/null)
        
        if [ "$HAS_DATA" != "0" ] && [ "$HAS_DATA" != "null" ] && [ -n "$HAS_DATA" ]; then
            cat "$EXPORT_DIR/raw/loki-all.json" | jq -r '
                .data.result[] | .stream as $labels | .values[] |
                [.[0], ($labels.app // "unknown"), ($labels.namespace // "default"), .[1]] | @csv
            ' > "$EXPORT_DIR/logs/all-logs.csv" 2>/dev/null
            
            if [ -s "$EXPORT_DIR/logs/all-logs.csv" ]; then
                sed -i '1i"timestamp_ns","app","namespace","log_message"' "$EXPORT_DIR/logs/all-logs.csv"
            else
                rm -f "$EXPORT_DIR/logs/all-logs.csv"
            fi
        else
            rm -f "$EXPORT_DIR/raw/loki-all.json"
        fi
    fi
}

export_prometheus_metrics() {
    if [ "$PROMETHEUS_ACCESSIBLE" != "true" ]; then
        return
    fi
    log "Exporting Prometheus metrics"
    
    declare -A METRICS=(
        ["container_cpu_usage"]='rate(container_cpu_usage_seconds_total{namespace="default",container!="",container!="POD"}[5m])'
        ["container_memory_usage"]='container_memory_working_set_bytes{namespace="default",container!="",container!="POD"}'
        ["container_network_receive"]='rate(container_network_receive_bytes_total{namespace="default"}[5m])'
        ["container_network_transmit"]='rate(container_network_transmit_bytes_total{namespace="default"}[5m])'
        ["pod_status"]='kube_pod_status_phase{namespace="default"}'
        ["pod_restarts"]='kube_pod_container_status_restarts_total{namespace="default"}'
        ["container_cpu_throttled"]='rate(container_cpu_cfs_throttled_seconds_total{namespace="default"}[5m])'
        ["container_oom_kills"]='kube_pod_container_status_terminated_reason{reason="OOMKilled",namespace="default"}'
    )
    
    for metric_name in "${!METRICS[@]}"; do
        query="${METRICS[$metric_name]}"
        
        log "Querying Prometheus metric ${metric_name}"
        curl_or_warn "prometheus metric ${metric_name}" "${CURL_BASE_ARGS[@]}" -G -s "$PROMETHEUS_URL/api/v1/query_range" \
            --data-urlencode "query=$query" \
            --data-urlencode "start=$START_TIME" \
            --data-urlencode "end=$END_TIME" \
            --data-urlencode "step=15s" \
            -o "$EXPORT_DIR/raw/prometheus-${metric_name}.json" 2>/dev/null
        
        if [ -f "$EXPORT_DIR/raw/prometheus-${metric_name}.json" ]; then
            HAS_DATA=$(cat "$EXPORT_DIR/raw/prometheus-${metric_name}.json" | jq -r '.data.result | length' 2>/dev/null)
            
            if [ "$HAS_DATA" != "0" ] && [ "$HAS_DATA" != "null" ] && [ -n "$HAS_DATA" ]; then
                cat "$EXPORT_DIR/raw/prometheus-${metric_name}.json" | jq -r '
                    .data.result[] | .metric as $labels | .values[] |
                    [.[0], .[1], ($labels.container // ""), ($labels.pod // ""),
                     ($labels.namespace // ""), ($labels.app // "")] | @csv
                ' > "$EXPORT_DIR/metrics/${metric_name}.csv" 2>/dev/null
                
                if [ -s "$EXPORT_DIR/metrics/${metric_name}.csv" ]; then
                    sed -i '1i"timestamp","value","container","pod","namespace","app"' "$EXPORT_DIR/metrics/${metric_name}.csv"
                else
                    rm -f "$EXPORT_DIR/metrics/${metric_name}.csv"
                fi
            else
                rm -f "$EXPORT_DIR/raw/prometheus-${metric_name}.json"
            fi
        fi
    done
}

export_latency_metrics() {
    if [ "$PROMETHEUS_ACCESSIBLE" != "true" ]; then
        return
    fi
    
    log "Exporting latency and error rate metrics"
    
    declare -A LATENCY_METRICS=(
        ["http_request_duration_p50"]='histogram_quantile(0.50, rate(http_request_duration_seconds_bucket{namespace="default"}[5m]))'
        ["http_request_duration_p95"]='histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{namespace="default"}[5m]))'
        ["http_request_duration_p99"]='histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{namespace="default"}[5m]))'
        ["http_error_rate"]='rate(http_requests_total{namespace="default",status=~"5.."}[5m])'
        ["http_request_rate"]='rate(http_requests_total{namespace="default"}[5m])'
    )
    
    for metric_name in "${!LATENCY_METRICS[@]}"; do
        query="${LATENCY_METRICS[$metric_name]}"
        
        log "Querying Prometheus latency metric ${metric_name}"
        curl_or_warn "prometheus latency metric ${metric_name}" "${CURL_BASE_ARGS[@]}" -G -s "$PROMETHEUS_URL/api/v1/query_range" \
            --data-urlencode "query=$query" \
            --data-urlencode "start=$START_TIME" \
            --data-urlencode "end=$END_TIME" \
            --data-urlencode "step=15s" \
            -o "$EXPORT_DIR/raw/prometheus-${metric_name}.json" 2>/dev/null
        
        if [ -f "$EXPORT_DIR/raw/prometheus-${metric_name}.json" ]; then
            HAS_DATA=$(cat "$EXPORT_DIR/raw/prometheus-${metric_name}.json" | jq -r '.data.result | length' 2>/dev/null)
            
            if [ "$HAS_DATA" != "0" ] && [ "$HAS_DATA" != "null" ] && [ -n "$HAS_DATA" ]; then
                cat "$EXPORT_DIR/raw/prometheus-${metric_name}.json" | jq -r '
                    .data.result[] | .metric as $labels | .values[] |
                    [.[0], .[1], ($labels.service // ""), ($labels.method // ""),
                     ($labels.path // ""), ($labels.status // "")] | @csv
                ' > "$EXPORT_DIR/metrics/${metric_name}.csv" 2>/dev/null
                
                if [ -s "$EXPORT_DIR/metrics/${metric_name}.csv" ]; then
                    sed -i '1i"timestamp","value","service","method","path","status"' "$EXPORT_DIR/metrics/${metric_name}.csv"
                else
                    rm -f "$EXPORT_DIR/metrics/${metric_name}.csv"
                fi
            else
                rm -f "$EXPORT_DIR/raw/prometheus-${metric_name}.json"
            fi
        fi
    done
}

export_service_metrics() {
    if [ "$PROMETHEUS_ACCESSIBLE" != "true" ]; then
        return
    fi
    log "Exporting per-service metrics"
    
    SERVICES=$($KUBECTL_CMD get pods -o jsonpath='{.items[*].metadata.labels.app}' | tr ' ' '\n' | sort -u | grep -v '^$')
    
    for service in $SERVICES; do
        query="rate(container_cpu_usage_seconds_total{namespace=\"default\",pod=~\"${service}.*\",container!=\"POD\"}[5m])"
        log "Querying Prometheus CPU for ${service}"
        curl_or_warn "prometheus cpu ${service}" "${CURL_BASE_ARGS[@]}" -G -s "$PROMETHEUS_URL/api/v1/query_range" \
            --data-urlencode "query=$query" \
            --data-urlencode "start=$START_TIME" \
            --data-urlencode "end=$END_TIME" \
            --data-urlencode "step=15s" \
            -o "$EXPORT_DIR/raw/service-${service}-cpu.json" 2>/dev/null
        
        if [ -f "$EXPORT_DIR/raw/service-${service}-cpu.json" ]; then
            HAS_DATA=$(cat "$EXPORT_DIR/raw/service-${service}-cpu.json" | jq -r '.data.result | length' 2>/dev/null)
            
            if [ "$HAS_DATA" != "0" ] && [ "$HAS_DATA" != "null" ] && [ -n "$HAS_DATA" ]; then
                cat "$EXPORT_DIR/raw/service-${service}-cpu.json" | jq -r '
                    .data.result[] | .values[] | [.[0], .[1]] | @csv
                ' > "$EXPORT_DIR/metrics/service-${service}-cpu.csv" 2>/dev/null
                
                if [ -s "$EXPORT_DIR/metrics/service-${service}-cpu.csv" ]; then
                    sed -i '1i"timestamp","cpu_usage_rate"' "$EXPORT_DIR/metrics/service-${service}-cpu.csv"
                else
                    rm -f "$EXPORT_DIR/metrics/service-${service}-cpu.csv"
                fi
            else
                rm -f "$EXPORT_DIR/raw/service-${service}-cpu.json"
            fi
        fi
        
        query="container_memory_working_set_bytes{namespace=\"default\",pod=~\"${service}.*\",container!=\"POD\"}"
        log "Querying Prometheus memory for ${service}"
        curl_or_warn "prometheus memory ${service}" "${CURL_BASE_ARGS[@]}" -G -s "$PROMETHEUS_URL/api/v1/query_range" \
            --data-urlencode "query=$query" \
            --data-urlencode "start=$START_TIME" \
            --data-urlencode "end=$END_TIME" \
            --data-urlencode "step=15s" \
            -o "$EXPORT_DIR/raw/service-${service}-memory.json" 2>/dev/null
        
        if [ -f "$EXPORT_DIR/raw/service-${service}-memory.json" ]; then
            HAS_DATA=$(cat "$EXPORT_DIR/raw/service-${service}-memory.json" | jq -r '.data.result | length' 2>/dev/null)
            
            if [ "$HAS_DATA" != "0" ] && [ "$HAS_DATA" != "null" ] && [ -n "$HAS_DATA" ]; then
                cat "$EXPORT_DIR/raw/service-${service}-memory.json" | jq -r '
                    .data.result[] | .values[] | [.[0], .[1]] | @csv
                ' > "$EXPORT_DIR/metrics/service-${service}-memory.csv" 2>/dev/null
                
                if [ -s "$EXPORT_DIR/metrics/service-${service}-memory.csv" ]; then
                    sed -i '1i"timestamp","memory_bytes"' "$EXPORT_DIR/metrics/service-${service}-memory.csv"
                else
                    rm -f "$EXPORT_DIR/metrics/service-${service}-memory.csv"
                fi
            else
                rm -f "$EXPORT_DIR/raw/service-${service}-memory.json"
            fi
        fi
    done
}

print_statistics() {
    LOG_FILES=$(find "$EXPORT_DIR/logs" -name "*.csv" -type f 2>/dev/null | wc -l)
    METRIC_FILES=$(find "$EXPORT_DIR/metrics" -name "*.csv" -type f 2>/dev/null | wc -l)
    EVENT_FILES=$(find "$EXPORT_DIR/events" -name "*.csv" -type f 2>/dev/null | wc -l)
    ANALYSIS_FILES=$(find "$EXPORT_DIR/analysis" -name "*.csv" -type f 2>/dev/null | wc -l)
    
    TOTAL_LOG_LINES=0
    if [ "$LOG_FILES" -gt 0 ]; then
        for file in "$EXPORT_DIR/logs"/*.csv; do
            if [ -f "$file" ]; then
                LINES=$(wc -l < "$file")
                TOTAL_LOG_LINES=$((TOTAL_LOG_LINES + LINES - 1))
            fi
        done
    fi
    
    TOTAL_METRIC_LINES=0
    if [ "$METRIC_FILES" -gt 0 ]; then
        for file in "$EXPORT_DIR/metrics"/*.csv; do
            if [ -f "$file" ]; then
                LINES=$(wc -l < "$file")
                TOTAL_METRIC_LINES=$((TOTAL_METRIC_LINES + LINES - 1))
            fi
        done
    fi
    
    log "Log files: $LOG_FILES ($TOTAL_LOG_LINES entries)"
    log "Metric files: $METRIC_FILES ($TOTAL_METRIC_LINES data points)"
    log "Event files: $EVENT_FILES"
    log "Analysis files: $ANALYSIS_FILES"
    
    if [ "$LOG_FILES" -eq 0 ] && [ "$METRIC_FILES" -eq 0 ]; then
        log "WARNING: No data files created. Try TIME_RANGE_HOURS=6 $0"
    fi
}

main() {
    log "Export start: $EXPORT_DIR"
    mkdir -p "$OUTPUT_DIR"
    setup_kubectl
    setup_urls
    verify_connectivity
    mkdir -p "$EXPORT_DIR"/{logs,metrics,metadata,raw,events,chaos,dependencies,analysis}
    
    log "Starting data export steps"
    export_metadata
    export_kubernetes_events
    export_chaos_timeline
    export_service_dependencies
    export_loki_logs
    parse_log_errors
    export_prometheus_metrics
    export_latency_metrics
    export_service_metrics
    print_statistics
    
    if [ "${COMPRESS:-false}" = "true" ]; then
        cd "$OUTPUT_DIR"
        tar -czf "export_${TIMESTAMP}.tar.gz" "export_${TIMESTAMP}" 2>/dev/null
        ln -sf "export_${TIMESTAMP}.tar.gz" latest-export.tar.gz
        log "Created archive: export_${TIMESTAMP}.tar.gz"
    fi
    
    log "Export complete: $EXPORT_DIR"
}

main "$@"
