import contextlib
import io
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
import show_place_check as spc  # noqa: E402


def poi(name, city, district="", address=""):
    return {"name": name, "cityname": city, "adname": district, "address": address}


class ShowPlaceCheckTests(unittest.TestCase):
    def test_t031zc_rules_match_the_app(self):
        """T-031zc F-09b §18 item 8: sure only for one exact name (branch ignored) in the asked city."""
        self.assertIsNotNone(spc.judge("清远新世界酒店", "清远", [poi("清远新世界酒店", "清远市")])[0])
        self.assertIsNotNone(spc.judge("星巴克", "清远", [poi("星巴克(大元路店)", "清远市")])[0])
        self.assertIsNone(spc.judge("星巴克", "清远", [poi("星巴克(A店)", "清远市"), poi("星巴克(B店)", "清远市")])[0])
        self.assertIsNone(spc.judge("悦天下生态度假区", "清远", [poi("清远清泉湾生态旅游度假区", "清远市")])[0])
        self.assertIsNone(spc.judge("悦天下生态度假区", "清远", [poi("悦天下生态度假区", "云浮市")])[0])
        self.assertEqual(len(spc.judge("x", "清远", [poi(f"p{i}", "清远市") for i in range(8)])[1]), 5)

    def test_t031zc_max_calls_dry_run_and_quota_stop(self):
        """T-031zc F-09b §18 item 8 / F-18 §32: --dry-run sends nothing; --max-calls caps; a quota error stops."""
        calls = []

        def get(key, name, city):
            calls.append(name)
            return {"status": "1", "pois": [poi(name, city + "市")]}

        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(spc.main(["--dry-run"], env={}, get=get), 0)
            self.assertEqual(calls, [])
            self.assertEqual(spc.main(["--max-calls", "2"], env={spc.KEY_ENV: "k"}, get=get), 0)
            self.assertEqual(len(calls), 2)
            quota = lambda *a: {"status": "0", "infocode": "10003", "info": "DAILY_QUERY_OVER_LIMIT"}  # noqa: E731
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(spc.main([], env={spc.KEY_ENV: "k"}, get=quota), 1)
                self.assertEqual(spc.main([], env={}, get=get), 2)


if __name__ == "__main__":
    unittest.main()
