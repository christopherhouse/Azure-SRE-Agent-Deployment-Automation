def main(total_requests: int, failed_requests: int, p95_latency_ms: float) -> dict:
    """Evaluate Checkout Lab availability and latency SLO posture."""
    safe_total = max(int(total_requests), 1)
    safe_failed = max(int(failed_requests), 0)
    error_rate = round((safe_failed / safe_total) * 100.0, 2)
    availability_pct = round(100.0 - error_rate, 2)
    latency_ms = round(float(p95_latency_ms), 2)

    availability_slo_pct = 99.0
    latency_slo_ms = 500.0
    availability_breached = availability_pct < availability_slo_pct
    latency_breached = latency_ms > latency_slo_ms

    if availability_breached and latency_breached:
        status = "CRITICAL"
    elif availability_breached or latency_breached:
        status = "DEGRADED"
    else:
        status = "HEALTHY"

    return {
        "status": status,
        "availabilityPct": availability_pct,
        "availabilitySloPct": availability_slo_pct,
        "availabilityBreached": availability_breached,
        "errorRatePct": error_rate,
        "p95LatencyMs": latency_ms,
        "latencySloMs": latency_slo_ms,
        "latencyBreached": latency_breached,
    }
