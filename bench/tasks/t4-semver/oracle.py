import importlib.util, sys, unittest
spec=importlib.util.spec_from_file_location("semver", sys.argv[1] if len(sys.argv)>1 else "semver.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c=m.semver_compare
class T(unittest.TestCase):
    def test_major(self): self.assertEqual(c("1.0.0","2.0.0"),-1)
    def test_patch(self): self.assertEqual(c("2.1.0","2.1.1"),-1)
    def test_eq(self): self.assertEqual(c("1.0.0","1.0.0"),0)
    def test_pre_lt_release(self): self.assertEqual(c("1.0.0-alpha","1.0.0"),-1)
    def test_release_gt_pre(self): self.assertEqual(c("1.0.0","1.0.0-alpha"),1)
    def test_fewer_fields(self): self.assertEqual(c("1.0.0-alpha","1.0.0-alpha.1"),-1)
    def test_numeric_ids(self): self.assertEqual(c("1.0.0-alpha.1","1.0.0-alpha.2"),-1)
    def test_numeric_not_lexical(self): self.assertEqual(c("1.0.0-alpha.2","1.0.0-alpha.11"),-1)
    def test_numeric_lt_alnum(self): self.assertEqual(c("1.0.0-alpha.1","1.0.0-alpha.beta"),-1)
    def test_beta_chain(self): self.assertEqual(c("1.0.0-beta.2","1.0.0-beta.11"),-1)
    def test_rc_lt_release(self): self.assertEqual(c("1.0.0-rc.1","1.0.0"),-1)
    def test_build_ignored(self): self.assertEqual(c("1.0.0+build","1.0.0"),0)
unittest.main(argv=["x"],verbosity=0,exit=False)
