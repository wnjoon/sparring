import importlib.util, sys, unittest
spec=importlib.util.spec_from_file_location("duration", sys.argv[1] if len(sys.argv)>1 else "duration.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
pd=m.parse_duration
class T(unittest.TestCase):
    def test_1h(self): self.assertEqual(pd("1h"),3600)
    def test_30m(self): self.assertEqual(pd("30m"),1800)
    def test_45s(self): self.assertEqual(pd("45s"),45)
    def test_combo(self): self.assertEqual(pd("1h30m"),5400)
    def test_combo3(self): self.assertEqual(pd("1h30m10s"),5410)
    def test_90m(self): self.assertEqual(pd("90m"),5400)
    def test_zero(self): self.assertEqual(pd("0s"),0)
    def test_empty(self):
        with self.assertRaises(ValueError): pd("")
    def test_no_unit(self):
        with self.assertRaises(ValueError): pd("1h30")
    def test_bad_unit(self):
        with self.assertRaises(ValueError): pd("10x")
    def test_negative(self):
        with self.assertRaises(ValueError): pd("-5s")
    def test_junk(self):
        with self.assertRaises(ValueError): pd("abc")
unittest.main(argv=["x"],verbosity=0,exit=False)
