#!/usr/bin/env python3
import csv
import sys
from pathlib import Path

# Usage example: ./scripts/plot-metrics.py [metrics_directory]

try:
    import matplotlib.pyplot as plt
except ImportError:  # pragma: no cover - runtime check
    print("ERROR: matplotlib is required. Install it with: pip install matplotlib")
    sys.exit(1)


ROOT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_METRICS_DIR = ROOT_DIR / "sample_data" / "metrics"
MAX_SERIES = 10


def read_metric_csv(csv_path):
    with csv_path.open(newline="") as handle:
        reader = csv.reader(handle)
        header = next(reader, None)
        if not header:
            return None, None, None

        rows = list(reader)

        ts_idx = None
        for candidate in ("timestamp", "timestamp_ns"):
            if candidate in header:
                ts_idx = header.index(candidate)
                break
        if ts_idx is None:
            return None, None, None

        val_idx = header.index("value") if "value" in header else None
        if val_idx is None:
            if len(header) == 2:
                val_idx = 1 if ts_idx == 0 else 0
            else:
                candidate_indices = [i for i in range(len(header)) if i != ts_idx]
                best_idx = None
                best_count = -1
                for idx in candidate_indices:
                    count = 0
                    for row in rows:
                        if len(row) <= idx:
                            continue
                        try:
                            float(row[idx])
                        except ValueError:
                            continue
                        else:
                            count += 1
                    if count > best_count:
                        best_count = count
                        best_idx = idx
                if best_idx is None or best_count == 0:
                    return None, None, None
                val_idx = best_idx

        label_indices = [i for i in range(len(header)) if i not in (ts_idx, val_idx)]
        series = {}
        for row in rows:
            if len(row) <= max(ts_idx, val_idx):
                continue
            try:
                timestamp = float(row[ts_idx])
                value = float(row[val_idx])
            except ValueError:
                continue
            label = tuple(row[i] for i in label_indices)
            series.setdefault(label, []).append((timestamp, value))
    return series, header, (ts_idx, val_idx)


def aggregate_series(series):
    bucket = {}
    for points in series.values():
        for timestamp, value in points:
            bucket.setdefault(timestamp, []).append(value)
    if not bucket:
        return [], []
    timestamps = sorted(bucket.keys())
    values = [sum(bucket[t]) / len(bucket[t]) for t in timestamps]
    return timestamps, values


def plot_metric(metric_name, series, output_path):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    plt.figure(figsize=(10, 4))

    if len(series) <= MAX_SERIES:
        for label, points in series.items():
            points = sorted(points, key=lambda x: x[0])
            timestamps = [p[0] for p in points]
            values = [p[1] for p in points]
            label_text = "/".join([part for part in label if part]) or "series"
            plt.plot(timestamps, values, linewidth=1, label=label_text)
        if len(series) > 1:
            plt.legend(fontsize="x-small", ncol=2, frameon=False)
    else:
        timestamps, values = aggregate_series(series)
        plt.plot(timestamps, values, linewidth=1, label="average")
        plt.legend(fontsize="x-small", frameon=False)

    plt.title(metric_name)
    plt.xlabel("timestamp")
    plt.ylabel("value")
    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    plt.close()


def discover_metric_sources(metrics_dir):
    return sorted(metrics_dir.rglob("*.csv"))


def plot_all_metrics(metrics_dir):
    csv_files = discover_metric_sources(metrics_dir)
    plots = []
    for csv_path in csv_files:
        metric_name = csv_path.stem
        series, _, _ = read_metric_csv(csv_path)
        if not series:
            print(f"Skipping {csv_path}: no data")
            continue
        output_path = csv_path.with_suffix(".png")
        print(f"Plotting {metric_name} -> {output_path}")
        plot_metric(metric_name, series, output_path)
        plots.append(output_path)
    return plots


def plot_combined(metrics_dir, plot_paths):
    if not plot_paths:
        print("No plots to combine")
        return

    images = []
    widths = []
    heights = []
    for path in plot_paths:
        image = plt.imread(path)
        images.append(image)
        heights.append(image.shape[0])
        widths.append(image.shape[1])

    total_height = sum(heights)
    max_width = max(widths)
    dpi = 100
    fig_height = max(2, total_height / dpi)
    fig_width = max(6, max_width / dpi)
    fig = plt.figure(figsize=(fig_width, fig_height), dpi=dpi)
    fig.subplots_adjust(left=0, right=1, top=1, bottom=0, hspace=0)

    y_offset = 0
    for image, height in zip(images, heights):
        ax = fig.add_axes([0, 1 - (y_offset + height) / total_height, 1, height / total_height])
        ax.imshow(image)
        ax.axis("off")
        y_offset += height

    output_path = metrics_dir / "combined-metrics.png"
    fig.savefig(output_path, dpi=dpi)
    plt.close(fig)
    print(f"Combined plot -> {output_path}")


def main():
    metrics_dir = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else DEFAULT_METRICS_DIR
    if not metrics_dir.exists():
        print(f"Metrics directory not found: {metrics_dir}")
        return 1

    plot_paths = plot_all_metrics(metrics_dir)
    plot_combined(metrics_dir, plot_paths)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
