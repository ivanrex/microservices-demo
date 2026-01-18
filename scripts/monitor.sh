#!/bin/bash

LOG_FILE="$HOME/chaos-setup.log"
CHAOS_MESH_VERSION="2.6.3"
HELM_VERSION="3.13.3"
DOCKER_CMD=""
USE_SUDO_DOCKER=false
KUBECTL_CMD=""
MINIKUBE_METHOD=""
WORKING_LOKI_URL=""

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE" 2>/dev/null || echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# System detection and setup functions

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
        log "Detected OS: $OS $VERSION"
    else
        log "Warning: Cannot detect OS version"
        OS="Unknown"
    fi
}

# Function to install basic dependencies
install_basic_dependencies() {
    log "Installing basic system dependencies..."
    
    # Update package list
    sudo apt update -y
    
    # Install essential tools
    sudo apt install -y \
        curl \
        wget \
        git \
        net-tools \
        lsof \
        ca-certificates \
        gnupg \
        software-properties-common \
        apt-transport-https \
        python3 \
        python3-pip \
        jq \
        htop \
        vim \
        unzip \
        psmisc \
        socat \
        conntrack
        
    log "Basic dependencies installed"
}

# Docker installation and configuration

# Function to install Docker
install_docker() {
    log "Installing Docker..."
    
    # Remove any old Docker installations
    sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Install Docker using the convenience script
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm -f get-docker.sh
    
    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Add current user to docker group
    sudo usermod -aG docker $USER
    
    # Fix Docker socket permissions
    sudo chmod 666 /var/run/docker.sock
    
    log "Docker installation completed"
}

# Function to test Docker access
setup_docker_access() {
    log "Setting up Docker access..."
    
    if docker ps >/dev/null 2>&1; then
        DOCKER_CMD="docker"
        USE_SUDO_DOCKER=false
        log "Docker accessible without sudo"
    else
        # Try to fix permissions
        sudo usermod -aG docker $USER
        sudo chmod 666 /var/run/docker.sock
        
        if docker ps >/dev/null 2>&1; then
            DOCKER_CMD="docker"
            USE_SUDO_DOCKER=false
            log "Docker accessible after permission fix"
        else
            DOCKER_CMD="sudo docker"
            USE_SUDO_DOCKER=true
            log "Docker requires sudo"
        fi
    fi
    
    # Test Docker with hello-world
    $DOCKER_CMD run --rm hello-world >/dev/null 2>&1 || { 
        log "Docker test failed"; 
        exit 1; 
    }
    log "Docker test successful"
}

# Kubernetes tools installation

# Function to install kubectl
install_kubectl() {
    if ! command_exists kubectl; then
        log "Installing kubectl..."
        
        local stable_version=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        if [ -z "$stable_version" ]; then
            log "Failed to determine kubectl stable version"
            return 1
        fi
        
        if ! curl -LO "https://dl.k8s.io/release/$stable_version/bin/linux/amd64/kubectl"; then
            log "Failed to download kubectl"
            return 1
        fi
        
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm -f kubectl
        log "kubectl $stable_version installed"
    else
        log "kubectl already installed: $(kubectl version --client --short 2>/dev/null | head -1)"
    fi
}

# Function to install minikube
install_minikube() {
    if ! command_exists minikube; then
        log "Installing Minikube..."
        
        if ! curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64; then
            log "Failed to download Minikube"
            return 1
        fi
        
        sudo install minikube-linux-amd64 /usr/local/bin/minikube
        rm -f minikube-linux-amd64
        log "Minikube installed"
    else
        log "Minikube already installed: $(minikube version --short 2>/dev/null)"
    fi
}

# Function to install additional tools
install_additional_tools() {
    log "Installing additional tools..."
    
    # Install yq if not present
    if ! command_exists yq; then
        sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
        sudo chmod +x /usr/local/bin/yq
        log "yq installed"
    fi
    
    log "Additional tools installed"
}

# Minikube cluster management

# Function to clean up previous installations
cleanup_previous() {
    log "Cleaning up previous installations..."
    
    # Kill any existing processes
    sudo pkill -f "minikube\|kubectl" 2>/dev/null || true
    
    # Stop and delete Minikube
    minikube stop 2>/dev/null || true
    minikube delete 2>/dev/null || true
    sudo minikube stop 2>/dev/null || true
    sudo minikube delete 2>/dev/null || true
    
    # Clean up directories
    rm -rf ~/.minikube ~/.kube 2>/dev/null || true
    sudo rm -rf /root/.minikube /root/.kube 2>/dev/null || true
    
    # Stop any existing Docker containers that might conflict
    if command_exists docker; then
        docker stop $(docker ps -q) 2>/dev/null || true
    fi
    
    sleep 5
    log "Cleanup completed"
}

# Function to start Minikube with better error handling
start_minikube() {
    log "Starting Minikube..."
    
    # Determine the best driver and configuration
    if [ "$USE_SUDO_DOCKER" = "true" ]; then
        log "Attempting Minikube with none driver (sudo required)..."
        if sudo minikube start --driver=none --kubernetes-version=v1.28.0; then
            KUBECTL_CMD="sudo kubectl"
            MINIKUBE_METHOD="none"
            log "Minikube started successfully with none driver"
        else
            log "Failed to start Minikube with none driver"
            exit 1
        fi
    else
        log "Attempting Minikube with docker driver..."
        if minikube start --driver=docker --memory=4096 --cpus=2; then
            KUBECTL_CMD="kubectl"
            MINIKUBE_METHOD="docker"
            log "Minikube started successfully with docker driver"
        elif minikube start --driver=docker --memory=2048 --cpus=1; then
            KUBECTL_CMD="kubectl"
            MINIKUBE_METHOD="docker"
            log "Minikube started with reduced resources"
        elif sudo minikube start --driver=none --kubernetes-version=v1.28.0; then
            KUBECTL_CMD="sudo kubectl"
            MINIKUBE_METHOD="none"
            log "Minikube started with none driver fallback"
        else
            log "All Minikube start attempts failed"
            exit 1
        fi
    fi
    
    # Wait for cluster to be ready
    log "Waiting for cluster to be ready..."
    sleep 30
    
    # Test kubectl access
    if ! $KUBECTL_CMD get nodes >/dev/null 2>&1; then
        if minikube kubectl -- get nodes >/dev/null 2>&1; then
            KUBECTL_CMD="minikube kubectl --"
            log "Using minikube kubectl wrapper"
        else
            log "Cannot access Kubernetes cluster"
            exit 1
        fi
    fi
    
    log "Kubernetes cluster is ready"
}

# Function to install Helm
install_helm() {
    if ! command_exists helm; then
        log "Installing Helm $HELM_VERSION..."
        
        if ! curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3; then
            log "Failed to download Helm installer"
            return 1
        fi
        
        chmod 700 get_helm.sh
        
        if ! ./get_helm.sh --version v$HELM_VERSION; then
            log "Failed to install Helm"
            rm -f get_helm.sh
            return 1
        fi
        
        rm -f get_helm.sh
        log "Helm $HELM_VERSION installed"
    else
        log "Helm already installed: $(helm version --short 2>/dev/null)"
    fi
    
    # Add repositories
    log "Adding Helm repositories..."
    helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo update
    log "Helm repositories updated"
}

# Application deployment

# Function to deploy boutique store
deploy_boutique() {
    log "Deploying boutique store..."
    cd ~
    # We don't delete existing directory in developing mode.
    #rm -rf microservices-demo 2>/dev/null

    # Instead, we check if the micro benchmark directory exists. If so, we use the existing one. Otherwise, we clone a new one.
    if [ -d microservices-demo ]; then
        echo "Directory ~/microservices-demo exists. Let's use the existing one..."
    else
        # The original repo is https://github.com/GoogleCloudPlatform/microservices-demo.git
	echo "Directory ~/microservices-demo doesn't exists. Let's clone one."
        if ! git clone git@github.com:ivanrex/microservices-demo.git; then
            log "Failed to clone boutique store repository. Exit with error."
            return 1
        fi
    fi
    cd microservices-demo
    
    if command_exists minikube && [ -x ./scripts/minikube-deploy.sh ]; then
        log "Building local images and updating manifests via minikube-deploy.sh..."
        if ! ./scripts/minikube-deploy.sh; then
            log "Failed to build images or apply Kubernetes manifests"
            return 1
        fi
    else
        if ! $KUBECTL_CMD apply -f ./release/kubernetes-manifests.yaml; then
            log "Failed to apply Kubernetes manifests"
            return 1
        fi
    fi
    
    # Wait for pods with better feedback
    log "Waiting for boutique pods to be ready..."
    for i in {1..30}; do
        NOT_READY=$($KUBECTL_CMD get pods --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
        TOTAL_PODS=$($KUBECTL_CMD get pods --no-headers 2>/dev/null | wc -l)
        
        log "Pod status check $i/30: $((TOTAL_PODS - NOT_READY))/$TOTAL_PODS pods ready"
        
        if [ $NOT_READY -eq 0 ] && [ $TOTAL_PODS -gt 0 ]; then
            log "All boutique pods are running"
            break
        fi
        
        if [ $i -eq 30 ]; then
            log "Timeout waiting for pods. Current status:"
            $KUBECTL_CMD get pods
        fi
        
        sleep 15
    done
    
    # Setup access
    log "Setting up boutique access..."
    $KUBECTL_CMD patch service frontend-external -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":8080,"nodePort":30080}]}}' 2>/dev/null || true
    
    if [ "$MINIKUBE_METHOD" != "none" ]; then
        nohup $KUBECTL_CMD port-forward --address=0.0.0.0 service/frontend-external 8080:80 > /tmp/boutique-port-forward.log 2>&1 &
        echo $! > /tmp/boutique-port-forward.pid
        log "Port forwarding setup for boutique"
    fi
    
    log "Boutique deployment completed"
}

# Observability stack installation

# Function to install Loki stack
install_loki_stack() {
    log "Installing Loki stack..."
    
    $KUBECTL_CMD create namespace loki-stack 2>/dev/null || true
    
    # Create Loki configuration with proper internal service setup
    cat > loki-values.yaml <<EOF
loki:
  auth_enabled: false
  server:
    http_listen_port: 3100
    grpc_listen_port: 9095
  commonConfig:
    replication_factor: 1
  storage:
    type: 'filesystem'
    filesystem:
      chunks_directory: /var/loki/chunks
      rules_directory: /var/loki/rules
  ingester:
    lifecycler:
      address: 127.0.0.1
      ring:
        kvstore:
          store: inmemory
        replication_factor: 1
      final_sleep: 0s
  schema_config:
    configs:
    - from: 2020-05-15
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
  storage_config:
    boltdb_shipper:
      active_index_directory: /var/loki/boltdb-shipper-active
      cache_location: /var/loki/boltdb-shipper-cache
      shared_store: filesystem
    filesystem:
      directory: /var/loki/chunks
  limits_config:
    enforce_metric_name: false
    reject_old_samples: true
    reject_old_samples_max_age: 168h
    ingestion_rate_mb: 16
    ingestion_burst_size_mb: 24
  chunk_store_config:
    max_look_back_period: 0s
  table_manager:
    retention_deletes_enabled: false
    retention_period: 0s
  service:
    type: ClusterIP
    port: 3100
  persistence:
    enabled: true
    size: 10Gi
  serviceMonitor:
    enabled: false
promtail:
  enabled: true
  config:
    logLevel: info
    serverPort: 3101
    clients:
      - url: http://loki:3100/loki/api/v1/push
grafana:
  enabled: false
fluent-bit:
  enabled: false
EOF
    
    helm upgrade --install loki grafana/loki-stack \
        --namespace loki-stack \
        -f loki-values.yaml \
        --timeout=15m \
        --wait
    
    # Create NodePort service for external access
    log "Creating NodePort service for external Loki access..."
    cat > loki-nodeport.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: loki-external
  namespace: loki-stack
spec:
  type: NodePort
  ports:
  - port: 3100
    targetPort: 3100
    nodePort: 30094
    protocol: TCP
  selector:
    app: loki
    release: loki
EOF
    
    $KUBECTL_CMD apply -f loki-nodeport.yaml
    
    # Wait for Loki to be ready
    log "Waiting for Loki to be ready..."
    for i in {1..20}; do
        if $KUBECTL_CMD get pods -n loki-stack -l app=loki --no-headers 2>/dev/null | grep -q "Running"; then
            log "Loki is running"
            
            # Test internal connectivity
            LOKI_POD=$($KUBECTL_CMD get pods -n loki-stack -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [ -n "$LOKI_POD" ]; then
                log "Testing Loki internal API..."
                if $KUBECTL_CMD exec -n loki-stack "$LOKI_POD" -- wget -qO- --timeout=5 "http://localhost:3100/ready" >/dev/null 2>&1; then
                    log "Loki internal API is working"
                else
                    log "Loki internal API is not responding"
                fi
            fi
            break
        fi
        log "Waiting for Loki... attempt $i/20"
        sleep 15
    done
    
    rm -f loki-values.yaml loki-nodeport.yaml
    log "Loki stack installation completed"
}

# Function to install monitoring stack with proper Loki integration
install_monitoring() {
    log "Installing monitoring stack with Loki integration..."
    
    $KUBECTL_CMD create namespace monitoring 2>/dev/null || true
    
    # Create custom values for comprehensive monitoring
    cat > prometheus-values.yaml <<EOF
# Prometheus configuration
prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    retention: 24h
    resources:
      requests:
        memory: 400Mi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    # Monitor all namespaces
    serviceMonitorNamespaceSelector: {}
    serviceMonitorSelector: {}
    podMonitorNamespaceSelector: {}
    podMonitorSelector: {}

# Service monitors configuration (Minikube-optimized)
# Note: Many control plane components are not accessible in Minikube
kubeApiServer:
  enabled: false  # Often not accessible in Minikube
kubelet:
  enabled: true
  serviceMonitor:
    cAdvisor: true
    probes: true
    resource: true
    resourcePath: "/metrics/resource"
kubeControllerManager:
  enabled: false  # Not accessible in Minikube docker/none driver
coreDns:
  enabled: true
kubeEtcd:
  enabled: false  # Not accessible in Minikube docker/none driver
kubeScheduler:
  enabled: false  # Not accessible in Minikube docker/none driver
kubeProxy:
  enabled: false  # Not accessible in Minikube docker/none driver
kubeStateMetrics:
  enabled: true

# Prometheus Operator configuration
prometheusOperator:
  enabled: true
  tls:
    enabled: false  # Disable TLS for Minikube compatibility

# Node exporter configuration
nodeExporter:
  enabled: true

# Grafana configuration
grafana:
  enabled: true
  service:
    type: NodePort
    nodePort: 30091
  adminPassword: admin123
  persistence:
    enabled: true
    size: 1Gi
  sidecar:
    dashboards:
      enabled: true
      defaultFolderName: "General"
    datasources:
      enabled: true

# Alertmanager configuration  
alertmanager:
  enabled: true
  service:
    type: NodePort
    nodePort: 30092
EOF
    
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        -f prometheus-values.yaml \
        --timeout=20m \
        --wait
    
    # Wait for Grafana to be ready before configuring datasource
    log "Waiting for Grafana to be ready..."
    for i in {1..30}; do
        if $KUBECTL_CMD get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -q "Running"; then
            log "Grafana is running"
            break
        fi
        log "Waiting for Grafana... attempt $i/30"
        sleep 10
    done
    
    rm -f prometheus-values.yaml
    log "Monitoring stack installation completed"
}

# Function to clean up non-working dashboards
cleanup_non_working_dashboards() {
    log "Cleaning up dashboards that won't work in Minikube..."
    
    # Determine Grafana URL
    if [ "$MINIKUBE_METHOD" != "none" ]; then
        MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "localhost")
        GRAFANA_URL="http://$MINIKUBE_IP:30091"
    else
        GRAFANA_URL="http://localhost:30091"
    fi
    
    # Wait for Grafana to be ready
    log "Waiting for Grafana API to be available..."
    for i in {1..20}; do
        if curl -s -f -u admin:admin123 "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
            log "Grafana API is ready"
            break
        fi
        if [ $i -eq 20 ]; then
            log "Grafana API not ready, skipping dashboard cleanup"
            return 1
        fi
        sleep 5
    done
    
    # List of dashboard UIDs/titles that won't work in Minikube
    # These are the typical dashboard titles from kube-prometheus-stack
    DASHBOARDS_TO_REMOVE=(
        "apiserver"
        "controller-manager"
        "scheduler"
        "proxy"
        "etcd"
    )
    
    log "Fetching dashboard list..."
    DASHBOARD_JSON=$(curl -s -u admin:admin123 "$GRAFANA_URL/api/search?type=dash-db" 2>/dev/null)
    
    if [ -z "$DASHBOARD_JSON" ]; then
        log "Could not fetch dashboard list"
        return 1
    fi
    
    # Delete dashboards with specific keywords
    DELETED_COUNT=0
    for keyword in "${DASHBOARDS_TO_REMOVE[@]}"; do
        # Find dashboard UIDs matching the keyword
        UIDS=$(echo "$DASHBOARD_JSON" | jq -r ".[] | select(.title | ascii_downcase | contains(\"$keyword\")) | .uid" 2>/dev/null)
        
        for uid in $UIDS; do
            if [ -n "$uid" ] && [ "$uid" != "null" ]; then
                TITLE=$(echo "$DASHBOARD_JSON" | jq -r ".[] | select(.uid==\"$uid\") | .title" 2>/dev/null)
                log "Deleting dashboard: $TITLE (UID: $uid)"
                
                if curl -s -X DELETE -u admin:admin123 "$GRAFANA_URL/api/dashboards/uid/$uid" >/dev/null 2>&1; then
                    ((DELETED_COUNT++))
                fi
            fi
        done
    done
    
    # Also remove Loki folder if it exists
    log "Removing Loki folder..."
    FOLDERS=$(curl -s -u admin:admin123 "$GRAFANA_URL/api/folders" 2>/dev/null)
    LOKI_FOLDER_UID=$(echo "$FOLDERS" | jq -r '.[] | select(.title=="Loki") | .uid' 2>/dev/null)
    
    if [ -n "$LOKI_FOLDER_UID" ] && [ "$LOKI_FOLDER_UID" != "null" ]; then
        curl -s -X DELETE -u admin:admin123 "$GRAFANA_URL/api/folders/$LOKI_FOLDER_UID" >/dev/null 2>&1
        log "Removed Loki folder"
    fi
    
    log "Dashboard cleanup completed - removed $DELETED_COUNT non-working dashboards"
}

# Function to configure Loki-Grafana connection
configure_loki_grafana_connection() {
    log "Configuring Loki-Grafana connection..."
    
    # Wait for both services to be ready
    log "Waiting for services to stabilize..."
    sleep 30
    
    # Get pod names
    GRAFANA_POD=$($KUBECTL_CMD get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    LOKI_POD=$($KUBECTL_CMD get pods -n loki-stack -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$GRAFANA_POD" ] || [ -z "$LOKI_POD" ]; then
        log "Cannot find required pods: Grafana=$GRAFANA_POD, Loki=$LOKI_POD"
        return 1
    fi
    
    log "Found Grafana pod: $GRAFANA_POD"
    log "Found Loki pod: $LOKI_POD"
    
    # Test DNS resolution and connectivity from multiple angles
    log "Testing DNS resolution from Grafana to Loki service..."
    
    # Test different service names
    WORKING_LOKI_URL=""
    for service_url in \
        "http://loki.loki-stack.svc.cluster.local:3100" \
        "http://loki.loki-stack:3100" \
        "http://loki:3100"; do
        
        log "Testing connectivity to: $service_url"
        if $KUBECTL_CMD exec -n monitoring "$GRAFANA_POD" -- nslookup "$(echo $service_url | sed 's|http://||' | sed 's|:.*||')" >/dev/null 2>&1; then
            log "DNS resolution works for $(echo $service_url | sed 's|http://||' | sed 's|:.*||')"
            
            if $KUBECTL_CMD exec -n monitoring "$GRAFANA_POD" -- wget -qO- --timeout=10 "$service_url/ready" >/dev/null 2>&1; then
                log "HTTP connectivity works to $service_url"
                WORKING_LOKI_URL="$service_url"
                break
            else
                log "HTTP connectivity failed to $service_url"
            fi
        else
            log "DNS resolution failed for $(echo $service_url | sed 's|http://||' | sed 's|:.*||')"
        fi
    done
    
    # If no working URL found, try to fix networking
    if [ -z "$WORKING_LOKI_URL" ]; then
        log "No working Loki URL found. Checking network policies and service status..."
        
        # Check if Loki service exists
        $KUBECTL_CMD get service -n loki-stack loki
        
        # Check endpoints
        $KUBECTL_CMD get endpoints -n loki-stack loki
        
        # Try direct pod IP
        LOKI_IP=$($KUBECTL_CMD get pod -n loki-stack "$LOKI_POD" -o jsonpath='{.status.podIP}')
        if [ -n "$LOKI_IP" ]; then
            log "Trying direct pod IP: $LOKI_IP"
            if $KUBECTL_CMD exec -n monitoring "$GRAFANA_POD" -- wget -qO- --timeout=10 "http://$LOKI_IP:3100/ready" >/dev/null 2>&1; then
                log "Direct pod IP works: http://$LOKI_IP:3100"
                WORKING_LOKI_URL="http://$LOKI_IP:3100"
            fi
        fi
    fi
    
    # Configure datasource with working URL
    if [ -n "$WORKING_LOKI_URL" ]; then
        log "Configuring Grafana datasource with URL: $WORKING_LOKI_URL"
        
        cat > loki-datasource.json <<EOF
{
  "name": "Loki-Fixed",
  "type": "loki",
  "url": "$WORKING_LOKI_URL",
  "access": "proxy",
  "isDefault": true,
  "jsonData": {
    "maxLines": 1000,
    "timeout": 60,
    "httpMethod": "GET"
  }
}
EOF
    else
        log "Cannot establish connectivity to Loki"
        return 1
    fi
    
    # Configure datasource via Grafana API
    if [ "$MINIKUBE_METHOD" != "none" ]; then
        MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "localhost")
        GRAFANA_URL="http://$MINIKUBE_IP:30091"
    else
        GRAFANA_URL="http://localhost:30091"
    fi
    
    log "Configuring datasource via Grafana API at $GRAFANA_URL..."
    for i in {1..15}; do
        if curl -s -f -u admin:admin123 "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
            log "Grafana API is ready"
            
            # Delete existing Loki datasources first
            curl -X DELETE -u admin:admin123 "$GRAFANA_URL/api/datasources/name/Loki" 2>/dev/null || true
            curl -X DELETE -u admin:admin123 "$GRAFANA_URL/api/datasources/name/Loki-Enhanced" 2>/dev/null || true
            curl -X DELETE -u admin:admin123 "$GRAFANA_URL/api/datasources/name/Loki-Fixed" 2>/dev/null || true
            
            sleep 2
            
            # Add new datasource
            if curl -X POST -H "Content-Type: application/json" -u admin:admin123 \
               -d @loki-datasource.json \
               "$GRAFANA_URL/api/datasources" 2>/dev/null; then
                log "Loki datasource configured successfully"
                
                # Test the datasource
                sleep 5
                if curl -X GET -u admin:admin123 "$GRAFANA_URL/api/datasources/proxy/uid/loki/loki/api/v1/labels" 2>/dev/null | grep -q "values"; then
                    log "Datasource test successful"
                else
                    log "Datasource added but test failed"
                fi
            else
                log "Failed to add datasource"
            fi
            break
        fi
        log "Waiting for Grafana API... attempt $i/15"
        sleep 10
    done
    
    rm -f loki-datasource.json
    log "Loki-Grafana connection configuration completed"
}

# Chaos engineering tools

# Function to install Chaos Mesh
install_chaos_mesh() {
    log "Installing Chaos Mesh..."
    
    $KUBECTL_CMD create namespace chaos-mesh 2>/dev/null || true
    
    # Install CRDs
    curl -sSL https://mirrors.chaos-mesh.org/v$CHAOS_MESH_VERSION/crd-v$CHAOS_MESH_VERSION.yaml | $KUBECTL_CMD apply -f -
    sleep 10
    
    # Install Chaos Mesh
    helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
        --namespace chaos-mesh \
        --version $CHAOS_MESH_VERSION \
        --set chaosDaemon.runtime=containerd \
        --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
        --set dashboard.securityMode=false \
        --set dashboard.service.type=NodePort \
        --set dashboard.service.nodePort=30093 \
        --timeout=15m \
        --wait
    
    log "Chaos Mesh installation completed"
}

# Function to create chaos experiments
create_chaos_experiments() {
    log "Creating chaos experiments..."
    
    mkdir -p chaos-experiments
    
    # Wait for cart service to be ready
    for i in {1..10}; do
        CART_PODS=$($KUBECTL_CMD get pods -l app=cartservice --no-headers 2>/dev/null | wc -l)
        if [ $CART_PODS -gt 0 ]; then
            break
        fi
        log "Waiting for cart service pods... attempt $i/10"
        sleep 10
    done
    
    if [ $CART_PODS -gt 0 ] && ! $KUBECTL_CMD get schedule scheduled-cart-killer 2>/dev/null | grep -q "scheduled-cart-killer"; then
        cat > chaos-experiments/cart-chaos.yaml <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: Schedule
metadata:
  name: scheduled-cart-killer
  namespace: default
spec:
  schedule: "@every 2m"
  historyLimit: 10
  concurrencyPolicy: "Forbid"
  type: "PodChaos"
  podChaos:
    action: pod-kill
    mode: one
    duration: "30s"
    selector:
      labelSelectors:
        app: cartservice
EOF
        
        $KUBECTL_CMD apply -f chaos-experiments/cart-chaos.yaml
        log "Cart killer chaos experiment created"
    else
        log "Cart service not ready or chaos experiment already exists"
    fi
}

# Function to create control script
create_control_script() {
    log "Creating control script..."
    
    cat > chaos-control.sh <<'EOF'
#!/bin/bash

# Determine kubectl command
if kubectl get nodes >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
elif sudo kubectl get nodes >/dev/null 2>&1; then
    KUBECTL_CMD="sudo kubectl"
elif minikube kubectl -- get nodes >/dev/null 2>&1; then
    KUBECTL_CMD="minikube kubectl --"
else
    echo "Cannot access Kubernetes cluster"
    exit 1
fi

# Determine URL base
if minikube ip >/dev/null 2>&1; then
    URL_BASE="http://$(minikube ip)"
else
    URL_BASE="http://localhost"
fi

case "$1" in
    status)
        echo "=== CLUSTER STATUS ==="
        $KUBECTL_CMD get nodes
        echo ""
        echo "=== BOUTIQUE PODS ==="
        $KUBECTL_CMD get pods | grep -E "(frontend|cart|product)" | head -5
        echo ""
        echo "=== LOKI STACK ==="
        $KUBECTL_CMD get pods -n loki-stack 2>/dev/null || echo "Loki not found"
        echo ""
        echo "=== MONITORING ==="
        $KUBECTL_CMD get pods -n monitoring | grep -E "(grafana|prometheus)" | head -3
        echo ""
        echo "=== CHAOS MESH ==="
        $KUBECTL_CMD get pods -n chaos-mesh 2>/dev/null || echo "Chaos Mesh not found"
        echo ""
        echo "=== CHAOS EXPERIMENTS ==="
        $KUBECTL_CMD get schedule,podchaos,stresschaos --all-namespaces 2>/dev/null || echo "No experiments running"
        ;;
    urls)
        echo "=== ACCESS URLS ==="
        echo "Boutique Store:  $URL_BASE:30080"
        echo "Chaos Dashboard: $URL_BASE:30093"
        echo "Grafana:        $URL_BASE:30091 (admin/admin123)"
        echo "Prometheus:     $URL_BASE:30090"
        echo "Loki:           $URL_BASE:30094"
        echo "Alertmanager:   $URL_BASE:30092"
        ;;
    test-loki)
        echo "Testing Loki connectivity..."
        GRAFANA_POD=$($KUBECTL_CMD get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        LOKI_POD=$($KUBECTL_CMD get pods -n loki-stack -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [ -n "$GRAFANA_POD" ] && [ -n "$LOKI_POD" ]; then
            echo "Testing multiple connection methods..."
            
            # Test 1: Service DNS
            echo "1. Testing service DNS..."
            for service in "loki.loki-stack.svc.cluster.local" "loki.loki-stack" "loki"; do
                if $KUBECTL_CMD exec -n monitoring "$GRAFANA_POD" -- nslookup "$service" >/dev/null 2>&1; then
                    echo "   DNS resolution works for $service"
                    if $KUBECTL_CMD exec -n monitoring "$GRAFANA_POD" -- wget -qO- --timeout=5 "http://$service:3100/ready" 2>/dev/null | grep -q "ready"; then
                        echo "   HTTP connectivity works to $service"
                    else
                        echo "   HTTP connectivity failed to $service"
                    fi
                else
                    echo "   DNS resolution failed for $service"
                fi
            done
            
            # Test 2: Direct pod IP
            echo "2. Testing direct pod IP..."
            LOKI_IP=$($KUBECTL_CMD get pod -n loki-stack "$LOKI_POD" -o jsonpath='{.status.podIP}')
            if [ -n "$LOKI_IP" ]; then
                echo "   Loki pod IP: $LOKI_IP"
                if $KUBECTL_CMD exec -n monitoring "$GRAFANA_POD" -- wget -qO- --timeout=5 "http://$LOKI_IP:3100/ready" 2>/dev/null | grep -q "ready"; then
                    echo "   Direct pod IP connectivity works"
                else
                    echo "   Direct pod IP connectivity failed"
                fi
            fi
            
            # Test 3: Service endpoints
            echo "3. Checking Loki service status..."
            $KUBECTL_CMD get service -n loki-stack loki
            $KUBECTL_CMD get endpoints -n loki-stack loki
            
            # Test 4: Port check
            echo "4. Testing port accessibility..."
            if $KUBECTL_CMD exec -n loki-stack "$LOKI_POD" -- netstat -tlnp | grep -q ":3100"; then
                echo "   Loki is listening on port 3100"
            else
                echo "   Loki is not listening on port 3100"
            fi
            
        else
            echo "Cannot find required pods: Grafana=$GRAFANA_POD, Loki=$LOKI_POD"
        fi
        ;;
    fix-loki)
        echo "Attempting to fix Loki datasource..."
        
        # Get pod info
        GRAFANA_POD=$($KUBECTL_CMD get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        LOKI_POD=$($KUBECTL_CMD get pods -n loki-stack -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        # Determine working URL
        WORKING_URL=""
        if [ -n "$GRAFANA_POD" ] && [ -n "$LOKI_POD" ]; then
            for service_url in \
                "http://loki.loki-stack.svc.cluster.local:3100" \
                "http://loki.loki-stack:3100" \
                "http://loki:3100"; do
                
                if $KUBECTL_CMD exec -n monitoring "$GRAFANA_POD" -- wget -qO- --timeout=5 "$service_url/ready" >/dev/null 2>&1; then
                    WORKING_URL="$service_url"
                    echo "Found working URL: $WORKING_URL"
                    break
                fi
            done
            
            # Try direct pod IP if service URLs fail
            if [ -z "$WORKING_URL" ]; then
                LOKI_IP=$($KUBECTL_CMD get pod -n loki-stack "$LOKI_POD" -o jsonpath='{.status.podIP}')
                if [ -n "$LOKI_IP" ]; then
                    if $KUBECTL_CMD exec -n monitoring "$GRAFANA_POD" -- wget -qO- --timeout=5 "http://$LOKI_IP:3100/ready" >/dev/null 2>&1; then
                        WORKING_URL="http://$LOKI_IP:3100"
                        echo "Using direct pod IP: $WORKING_URL"
                    fi
                fi
            fi
        fi
        
        if [ -z "$WORKING_URL" ]; then
            echo "Cannot find working Loki URL. Check if Loki is running:"
            $KUBECTL_CMD get pods -n loki-stack
            exit 1
        fi
        
        # Configure Grafana
        if [ "$URL_BASE" = "http://localhost" ]; then
            GRAFANA_URL="http://localhost:30091"
        else
            GRAFANA_URL="$URL_BASE:30091"
        fi
        
        cat > /tmp/loki-datasource.json <<DATASOURCE_EOF
{
  "name": "Loki-Fixed",
  "type": "loki",
  "url": "$WORKING_URL",
  "access": "proxy",
  "isDefault": true,
  "jsonData": {
    "maxLines": 1000,
    "timeout": 60,
    "httpMethod": "GET"
  }
}
DATASOURCE_EOF
        
        # Remove existing datasources
        curl -X DELETE -u admin:admin123 "$GRAFANA_URL/api/datasources/name/Loki" 2>/dev/null || true
        curl -X DELETE -u admin:admin123 "$GRAFANA_URL/api/datasources/name/Loki-Enhanced" 2>/dev/null || true
        curl -X DELETE -u admin:admin123 "$GRAFANA_URL/api/datasources/name/Loki-Fixed" 2>/dev/null || true
        sleep 2
        
        if curl -X POST -H "Content-Type: application/json" -u admin:admin123 \
           -d @/tmp/loki-datasource.json \
           "$GRAFANA_URL/api/datasources" 2>/dev/null; then
            echo "Loki datasource added successfully with URL: $WORKING_URL"
            
            # Test the datasource
            sleep 3
            echo "Testing datasource..."
            if curl -s -u admin:admin123 "$GRAFANA_URL/api/datasources" | grep -q "Loki-Fixed"; then
                echo "Datasource is configured"
            fi
        else
            echo "Failed to configure datasource"
        fi
        rm -f /tmp/loki-datasource.json
        ;;
    debug-network)
        echo "Network Debugging"
        echo "Grafana pods:"
        $KUBECTL_CMD get pods -n monitoring -l app.kubernetes.io/name=grafana
        echo ""
        echo "Loki pods:"
        $KUBECTL_CMD get pods -n loki-stack -l app=loki
        echo ""
        echo "Loki services:"
        $KUBECTL_CMD get services -n loki-stack
        echo ""
        echo "Loki endpoints:"
        $KUBECTL_CMD get endpoints -n loki-stack loki
        echo ""
        echo "Network policies (if any):"
        $KUBECTL_CMD get networkpolicies --all-namespaces 2>/dev/null || echo "No network policies found"
        ;;
    restart-loki)
        echo "Restarting Loki deployment..."
        $KUBECTL_CMD rollout restart deployment/loki -n loki-stack
        echo "Waiting for Loki to be ready..."
        $KUBECTL_CMD rollout status deployment/loki -n loki-stack --timeout=300s
        echo "Loki restarted"
        ;;
    cleanup-dashboards)
        echo "Cleaning up non-working Grafana dashboards..."
        
        DASHBOARDS_TO_REMOVE=("apiserver" "controller-manager" "scheduler" "proxy" "etcd")
        GRAFANA_URL="$URL_BASE:30091"
        
        echo "Fetching dashboard list..."
        DASHBOARD_JSON=$(curl -s -u admin:admin123 "$GRAFANA_URL/api/search?type=dash-db" 2>/dev/null)
        
        if [ -z "$DASHBOARD_JSON" ]; then
            echo "Could not fetch dashboard list. Is Grafana running?"
            exit 1
        fi
        
        DELETED_COUNT=0
        for keyword in "${DASHBOARDS_TO_REMOVE[@]}"; do
            UIDS=$(echo "$DASHBOARD_JSON" | jq -r ".[] | select(.title | ascii_downcase | contains(\"$keyword\")) | .uid" 2>/dev/null)
            
            for uid in $UIDS; do
                if [ -n "$uid" ] && [ "$uid" != "null" ]; then
                    TITLE=$(echo "$DASHBOARD_JSON" | jq -r ".[] | select(.uid==\"$uid\") | .title" 2>/dev/null)
                    echo "Deleting: $TITLE"
                    
                    if curl -s -X DELETE -u admin:admin123 "$GRAFANA_URL/api/dashboards/uid/$uid" >/dev/null 2>&1; then
                        ((DELETED_COUNT++))
                    fi
                fi
            done
        done
        
        # Remove Loki folder
        FOLDERS=$(curl -s -u admin:admin123 "$GRAFANA_URL/api/folders" 2>/dev/null)
        LOKI_FOLDER_UID=$(echo "$FOLDERS" | jq -r '.[] | select(.title=="Loki") | .uid' 2>/dev/null)
        
        if [ -n "$LOKI_FOLDER_UID" ] && [ "$LOKI_FOLDER_UID" != "null" ]; then
            curl -s -X DELETE -u admin:admin123 "$GRAFANA_URL/api/folders/$LOKI_FOLDER_UID" >/dev/null 2>&1
            echo "Removed Loki folder"
        fi
        
        echo "Cleanup completed - removed $DELETED_COUNT dashboards"
        ;;
    stop-chaos)
        echo "Stopping all chaos experiments..."
        $KUBECTL_CMD delete podchaos,stresschaos --all 2>/dev/null || echo "No experiments to stop"
        ;;
    stop-cart-killer)
        echo "Stopping cart killer schedule..."
        $KUBECTL_CMD delete schedule scheduled-cart-killer 2>/dev/null || echo "Cart killer schedule not found"
        ;;
    start-cart-killer)
        echo "Starting cart killer schedule..."
        if [ -f chaos-experiments/cart-chaos.yaml ]; then
            $KUBECTL_CMD apply -f chaos-experiments/cart-chaos.yaml
        else
            echo "Cart chaos experiment file not found"
        fi
        ;;
    logs)
        service=${2:-frontend}
        echo "Showing logs for $service..."
        $KUBECTL_CMD logs -l app=$service --tail=50
        ;;
    *)
        echo "Chaos Engineering Control Script"
        echo "Usage: $0 {status|urls|test-loki|fix-loki|cleanup-dashboards|debug-network|restart-loki|stop-chaos|stop-cart-killer|start-cart-killer|logs} [service]"
        echo ""
        echo "Commands:"
        echo "  status              - Show status of all components"
        echo "  urls                - Show access URLs"
        echo "  test-loki           - Test Loki connectivity from Grafana (comprehensive)"
        echo "  fix-loki            - Fix Loki datasource in Grafana (smart detection)"
        echo "  cleanup-dashboards  - Remove non-working dashboards (API Server, etcd, etc.)"
        echo "  debug-network       - Debug network connectivity issues"
        echo "  restart-loki        - Restart Loki deployment"
        echo "  stop-chaos          - Stop all chaos experiments"
        echo "  stop-cart-killer    - Stop cart killer schedule"
        echo "  start-cart-killer   - Start cart killer schedule"
        echo "  logs [service]      - Show logs for service (default: frontend)"
        echo ""
        echo "Troubleshooting Loki connection issues:"
        echo "  1. Run: $0 test-loki"
        echo "  2. If tests fail, run: $0 debug-network"
        echo "  3. Try: $0 restart-loki"
        echo "  4. Finally: $0 fix-loki"
        echo ""
        echo "Examples:"
        echo "  $0 status"
        echo "  $0 cleanup-dashboards"
        echo "  $0 test-loki"
        echo "  $0 fix-loki"
        echo "  $0 logs cartservice"
        echo "  $0 stop-cart-killer"
        ;;
esac
EOF

    chmod +x chaos-control.sh
    log "Control script created"
}

# Main execution

main() {
    log "Starting Chaos Engineering Setup"
    
    # Detect OS
    detect_os
    
    # Step 1: Install basic dependencies
    log "Step 1/10: Installing basic dependencies..."
    install_basic_dependencies || { log "Failed to install basic dependencies"; exit 1; }
    
    # Step 2: Install and setup Docker
    log "Step 2/10: Setting up Docker..."
    if ! command_exists docker; then
        install_docker || { log "Failed to install Docker"; exit 1; }
    fi
    setup_docker_access || { log "Failed to setup Docker access"; exit 1; }
    
    # Step 3: Install Kubernetes tools
    log "Step 3/10: Installing Kubernetes tools..."
    install_kubectl || { log "Failed to install kubectl"; exit 1; }
    install_minikube || { log "Failed to install Minikube"; exit 1; }
    
    # Step 4: Install additional tools
    log "Step 4/10: Installing additional tools..."
    install_additional_tools || { log "Failed to install additional tools"; exit 1; }
    
    # Step 5: Clean up and start Minikube
    log "Step 5/10: Starting Minikube cluster..."
    cleanup_previous
    start_minikube || { log "Failed to start Minikube"; exit 1; }
    
    # Step 6: Install Helm
    log "Step 6/10: Installing Helm..."
    install_helm || { log "Failed to install Helm"; exit 1; }
    
    # Step 7: Deploy boutique store
    log "Step 7/10: Deploying boutique store..."
    deploy_boutique || { log "Failed to deploy boutique store"; exit 1; }
    
    # Step 8: Install observability stack
    log "Step 8/10: Installing observability stack..."
    install_loki_stack || { log "Failed to install Loki stack"; exit 1; }
    install_monitoring || { log "Failed to install monitoring stack"; exit 1; }
    configure_loki_grafana_connection || log "Loki-Grafana connection may need manual fixing"
    cleanup_non_working_dashboards || log "Dashboard cleanup had issues"
    
    # Step 9: Install chaos engineering
    log "Step 9/10: Installing Chaos Mesh..."
    install_chaos_mesh || { log "Failed to install Chaos Mesh"; exit 1; }
    #create_chaos_experiments || log "Failed to create chaos experiments"
    
    # Step 10: Create management tools
    log "Step 10/10: Creating management tools..."
    create_control_script
    
    # Display final output
    display_completion_message
}

# Function to display completion message
display_completion_message() {
    echo ""
    echo "Setup Complete"
    echo ""
    
    # Determine URLs based on Minikube method
    if [ "$MINIKUBE_METHOD" = "none" ]; then
        local base_url="localhost"
    else
        local base_url=$(minikube ip 2>/dev/null || echo "localhost")
    fi
    
    echo "Access URLs:"
    echo "  Boutique Store:  http://$base_url:30080"
    echo "  Chaos Dashboard: http://$base_url:30093"
    echo "  Grafana:         http://$base_url:30091 (admin/admin123)"
    echo "  Prometheus:      http://$base_url:30090"
    echo "  Loki:            http://$base_url:30094/loki/api/v1/labels"
    echo "  Alertmanager:    http://$base_url:30092"
    echo ""
    echo "Control script: ./chaos-control.sh"
    echo "Setup log: $LOG_FILE"
    echo ""
    echo "Wait 2-3 minutes for all services to start"
    echo ""
    
    # Try to open browser
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "http://$base_url:30080" 2>/dev/null &
    fi
    
    log "Setup completed successfully"
}

# Execute main function
main
