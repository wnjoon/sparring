import importlib.util, sys, unittest
spec=importlib.util.spec_from_file_location("lru", sys.argv[1] if len(sys.argv)>1 else "lru.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
L=m.LRUCache
class T(unittest.TestCase):
    def test_get_recency(self):
        c=L(2); c.put("a",1); c.put("b",2); self.assertEqual(c.get("a"),1)
        c.put("c",3)  # b is LRU → evicted
        self.assertIsNone(c.get("b")); self.assertEqual(c.get("a"),1); self.assertEqual(c.get("c"),3)
    def test_update_existing(self):
        c=L(2); c.put("a",1); c.put("b",2); c.put("a",9)  # a MRU
        c.put("c",3)  # b evicted
        self.assertEqual(c.get("a"),9); self.assertIsNone(c.get("b"))
    def test_cap1(self):
        c=L(1); c.put("a",1); c.put("b",2)
        self.assertIsNone(c.get("a")); self.assertEqual(c.get("b"),2)
    def test_miss(self):
        c=L(2); self.assertIsNone(c.get("x"))
unittest.main(argv=["x"],verbosity=0,exit=False)
