"""Synthetic checkout traffic only; stdout is collected by Azure Monitor."""

import json
import os
import time
from datetime import datetime, timezone


def fault_enabled(value):
    if value not in ("true", "false"):
        raise ValueError("CHECKOUT_FAULT_ENABLED must be 'true' or 'false'")
    return value == "true"


def checkout_event(sequence, inject_fault):
    failed = inject_fault and sequence % 5 == 0
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service": "checkout",
        "event": "checkout_completed",
        "order_id": f"synthetic-{sequence:08d}",
        "synthetic": True,
        "fault_enabled": inject_fault,
        "status": "failed" if failed else "succeeded",
        "error_code": "PAYMENT_PROVIDER_TIMEOUT" if failed else None,
        "dependency": "synthetic-payment-provider",
        "duration_ms": 3000 if failed else 42,
        "message": (
            "Controlled payment timeout; disable CHECKOUT_FAULT_ENABLED to recover."
            if failed
            else "Synthetic payment accepted."
        ),
    }


def main():
    inject_fault = fault_enabled(os.environ.get("CHECKOUT_FAULT_ENABLED", "false"))
    sequence = 1
    while True:
        print(json.dumps(checkout_event(sequence, inject_fault)), flush=True)
        sequence += 1
        time.sleep(10)


if __name__ == "__main__":
    main()
