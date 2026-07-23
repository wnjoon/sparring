import importlib.util, sys, unittest
spec=importlib.util.spec_from_file_location("paginate", sys.argv[1] if len(sys.argv)>1 else "paginate.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
pg=m.paginate
R=list(range(1,11))
class T(unittest.TestCase):
    def test_p1(self): self.assertEqual(pg(R,3,1),[1,2,3])
    def test_p2(self): self.assertEqual(pg(R,3,2),[4,5,6])
    def test_last_partial(self): self.assertEqual(pg(R,3,4),[10])
    def test_beyond(self): self.assertEqual(pg(R,3,5),[])
    def test_big_size(self): self.assertEqual(pg(R,100,1),R)
    def test_empty(self): self.assertEqual(pg([],3,1),[])
    def test_bad_size(self):
        with self.assertRaises(ValueError): pg(R,0,1)
    def test_bad_page(self):
        with self.assertRaises(ValueError): pg(R,3,0)
unittest.main(argv=["x"],verbosity=0,exit=False)
