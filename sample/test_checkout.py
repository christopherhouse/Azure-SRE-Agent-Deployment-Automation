import json
import unittest

from checkout import checkout_event, fault_enabled


class CheckoutTests(unittest.TestCase):
    def test_healthy_traffic_including_fifth_checkout(self):
        events = [checkout_event(i, False) for i in range(1, 11)]
        self.assertTrue(all(event["status"] == "succeeded" for event in events))
        self.assertTrue(all(event["error_code"] is None for event in events))

    def test_controlled_fault_is_correlatable_and_recovers(self):
        events = [checkout_event(i, True) for i in range(1, 11)]
        failures = [event for event in events if event["status"] == "failed"]
        self.assertEqual([event["order_id"] for event in failures],
                         ["synthetic-00000005", "synthetic-00000010"])
        self.assertEqual(failures[0]["error_code"], "PAYMENT_PROVIDER_TIMEOUT")
        self.assertEqual(checkout_event(5, False)["status"], "succeeded")
        self.assertEqual(len({event["order_id"] for event in events}), 10)
        self.assertTrue(all(json.loads(json.dumps(event)) == event for event in events))

    def test_fault_switch_rejects_misconfiguration(self):
        self.assertFalse(fault_enabled("false"))
        self.assertTrue(fault_enabled("true"))
        for value in ("TRUE", "1", "", "enabled"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                fault_enabled(value)


if __name__ == "__main__":
    unittest.main()
