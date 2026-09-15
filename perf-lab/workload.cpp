// CadQuery-like workload: primitives, booleans, fillet/chamfer, spline
// extrude/loft/sweep, shell, mesh, mass properties, distances, section.
// Linked against clang -fprofile-instr-generate libs to collect execution counts.
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Section.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <GeomAPI_PointsToBSpline.hxx>
#include <Geom_BSplineCurve.hxx>
#include <GC_MakeCircle.hxx>
#include <Geom_Circle.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Edge.hxx>
#include <NCollection_List.hxx>
#include <gp_Trsf.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Pln.hxx>
#include <BRep_Tool.hxx>
#include <BRepTools.hxx>
#include <Poly_Triangulation.hxx>
#include <TopLoc_Location.hxx>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>

static TopoDS_Shape g_last, g_probe;
static double g_stage[16]; static double g_t;
static double now();
static void stage(int k) { double t = now(); g_stage[k] += t - g_t; g_t = t; }

static double now()
{
  return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static TopoDS_Shape splineWire(double z, double scale)
{
  NCollection_Array1<gp_Pnt> pts(1, 8);
  for (int i = 1; i <= 8; ++i)
  {
    double a = 2 * M_PI * (i - 1) / 8;
    double r = scale * (1.0 + 0.3 * std::sin(3 * a));
    pts(i) = gp_Pnt(r * std::cos(a), r * std::sin(a), z);
  }
  GeomAPI_PointsToBSpline fit(pts, 3, 8, GeomAbs_C2, 1e-6);
  occ::handle<Geom_BSplineCurve> c = fit.Curve();
  c->SetPeriodic();
  TopoDS_Edge e = BRepBuilderAPI_MakeEdge(c);
  return BRepBuilderAPI_MakeWire(e);
}

static void fuseAll(TopoDS_Shape& acc, const TopoDS_Shape& s, const char* n = "")
{
  BRepAlgoAPI_Fuse f(acc, s);
  f.SetRunParallel(false);
  if (f.IsDone() && !f.Shape().IsNull()) acc = f.Shape();
  else std::printf("  fuse %s failed (kept previous)\n", n);
}

static void chk(const char* n, const TopoDS_Shape& s)
{
  if (s.IsNull()) std::printf("  [%s] NULL\n", n);
}

static long countTriangles(const TopoDS_Shape& s)
{
  long n = 0;
  for (TopExp_Explorer ex(s, TopAbs_FACE); ex.More(); ex.Next())
  {
    TopLoc_Location loc;
    occ::handle<Poly_Triangulation> t = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
    if (!t.IsNull()) n += t->NbTriangles();
  }
  return n;
}

int main(int argc, char** argv)
{
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  int reps = argc > 1 ? std::atoi(argv[1]) : 1;
  double t0 = now();
  for (int rep = 0; rep < reps; ++rep)
  {
    // 1. plate with holes, fillet, chamfer
    g_t = now();
    TopoDS_Shape plate = BRepPrimAPI_MakeBox(gp_Pnt(-50, -30, 0), 100, 60, 20);
    {
      BRepFilletAPI_MakeFillet fil(plate);
      for (TopExp_Explorer ex(plate, TopAbs_EDGE); ex.More(); ex.Next())
        fil.Add(3.0, TopoDS::Edge(ex.Current()));
      fil.Build();
      if (fil.IsDone()) plate = fil.Shape(); else std::printf("  fillet failed\n");
    }
    for (int i = 0; i < 4; ++i)
    {
      double x = (i % 2 ? 35 : -35), y = (i / 2 ? 20 : -20);
      TopoDS_Shape hole = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(x, y, -1), gp_Dir(0, 0, 1)), 6, 30);
      BRepAlgoAPI_Cut cut(plate, hole);
      plate = cut.Shape();
    }
    {
      BRepFilletAPI_MakeChamfer ch(plate);
      for (TopExp_Explorer ex(plate, TopAbs_EDGE); ex.More(); ex.Next())
      {
        Bnd_Box eb; BRepBndLib::Add(ex.Current(), eb);
        double x0, y0, z0, x1, y1, z1; eb.Get(x0, y0, z0, x1, y1, z1);
        if (z0 > 19.0 && x1 - x0 < 13.0) ch.Add(1.0, TopoDS::Edge(ex.Current()));
      }
      ch.Build();
      if (ch.IsDone()) plate = ch.Shape(); else std::printf("  chamfer failed\n");
    }
    chk("plate+fillet", plate);
    stage(0);

    // 2. spline extrude, sphere fuse, chamfer top edges
    TopoDS_Shape prof = splineWire(20, 15);
    TopoDS_Shape face = BRepBuilderAPI_MakeFace(TopoDS::Wire(prof), true);
    TopoDS_Shape boss = BRepPrimAPI_MakePrism(face, gp_Vec(0, 0, 25));
    TopoDS_Shape ball = BRepPrimAPI_MakeSphere(gp_Pnt(0, 0, 45), 12);
    chk("boss", boss);
    fuseAll(boss, ball, "ball");
    chk("boss+ball", boss);
    fuseAll(plate, boss, "boss");
    chk("plate+boss", plate);
    stage(1);

    // 3. loft between spline sections, cut from plate
    BRepOffsetAPI_ThruSections loft(true, false);
    loft.AddWire(TopoDS::Wire(splineWire(-5, 8)));
    loft.AddWire(TopoDS::Wire(splineWire(10, 6)));
    loft.AddWire(TopoDS::Wire(splineWire(25, 9)));
    loft.Build();
    TopoDS_Shape lofted = loft.Shape();
    {
      gp_Trsf tr; tr.SetTranslation(gp_Vec(20, 0, 0));
      lofted = BRepBuilderAPI_Transform(lofted, tr, true).Shape();
      BRepAlgoAPI_Cut cut(plate, lofted);
      plate = cut.Shape();
    }
    chk("plate-loft", plate);
    stage(2);

    // 4. sweep circle along spline path, fuse
    {
      NCollection_Array1<gp_Pnt> pts(1, 5);
      for (int i = 1; i <= 5; ++i)
        pts(i) = gp_Pnt(-40 + 20 * (i - 1), 4 * std::sin(i), 30 + 2 * i);
      GeomAPI_PointsToBSpline fit(pts, 3, 8, GeomAbs_C2, 1e-6);
      TopoDS_Edge pathE = BRepBuilderAPI_MakeEdge(fit.Curve());
      TopoDS_Wire path = BRepBuilderAPI_MakeWire(pathE);
      gp_Pnt p0 = pts(1);
      gp_Dir d0(pts(2).XYZ() - pts(1).XYZ());
      occ::handle<Geom_Circle> circ = GC_MakeCircle(gp_Ax2(p0, d0), 3.0).Value();
      TopoDS_Wire cw = BRepBuilderAPI_MakeWire(BRepBuilderAPI_MakeEdge(circ));
      TopoDS_Shape cf = BRepBuilderAPI_MakeFace(cw, true);
      TopoDS_Shape pipe = BRepOffsetAPI_MakePipe(path, cf).Shape();
      chk("pipe", pipe);
      fuseAll(plate, pipe, "pipe");
    }
    chk("plate+pipe", plate);
    stage(3);

    // 5. shell (thick solid) of a box, then common with a rotated cylinder
    {
      TopoDS_Shape box = BRepPrimAPI_MakeBox(gp_Pnt(60, -20, 0), 40, 40, 40);
      NCollection_List<TopoDS_Shape> faces;
      TopExp_Explorer ex(box, TopAbs_FACE);
      faces.Append(ex.Current());
      BRepOffsetAPI_MakeThickSolid th;
      th.MakeThickSolidByJoin(box, faces, -2.0, 1e-3);
      TopoDS_Shape shell = th.IsDone() ? th.Shape() : box;
      chk("shell", shell);
      gp_Trsf rot; rot.SetRotation(gp_Ax1(gp_Pnt(80, 0, 20), gp_Dir(1, 1, 0)), 0.7);
      TopoDS_Shape cyl = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(80, 0, -30), gp_Dir(0, 0, 1)), 15, 100);
      cyl = BRepBuilderAPI_Transform(cyl, rot, true).Shape();
      BRepAlgoAPI_Common common(shell, cyl);
      chk("common", common.Shape());
      fuseAll(plate, common.Shape(), "common");
    }
    chk("plate+common", plate);
    stage(4);

    // 6. revolve spline profile
    {
      NCollection_Array1<gp_Pnt> pts(1, 6);
      for (int i = 1; i <= 6; ++i) pts(i) = gp_Pnt(-70 + 4 * std::sin(i), 0, 5 * i);
      GeomAPI_PointsToBSpline fit(pts, 3, 8, GeomAbs_C2, 1e-6);
      TopoDS_Edge pe = BRepBuilderAPI_MakeEdge(fit.Curve());
      gp_Pnt a0(-80, 0, 5), a1(-80, 0, 30);
      BRepBuilderAPI_MakeWire pw(pe);
      pw.Add(BRepBuilderAPI_MakeEdge(pts(6), a1));
      pw.Add(BRepBuilderAPI_MakeEdge(a1, a0));
      pw.Add(BRepBuilderAPI_MakeEdge(a0, pts(1)));
      TopoDS_Shape pf = BRepBuilderAPI_MakeFace(pw.Wire(), true);
      TopoDS_Shape rev = BRepPrimAPI_MakeRevol(pf, gp_Ax1(gp_Pnt(-80, 0, 0), gp_Dir(0, 0, 1)), 2 * M_PI);
      Bnd_Box bb; BRepBndLib::Add(rev, bb);
      chk("rev", rev);
      fuseAll(plate, rev, "rev");
    }
    chk("plate+rev", plate);
    stage(5);

    // 7. mesh, mass props, distance, section, check
    BRepMesh_IncrementalMesh mesh(plate, 0.1, false, 0.5, false);
    long tris = countTriangles(plate);
    stage(6);
    GProp_GProps props;
    BRepGProp::VolumeProperties(plate, props);
    stage(7);
    TopoDS_Shape probe = BRepPrimAPI_MakeSphere(gp_Pnt(0, 100, 100), 5);
    BRepExtrema_DistShapeShape dist(plate, probe);
    stage(8);
    BRepAlgoAPI_Section sec(plate, gp_Pln(gp_Pnt(0, 0, 10), gp_Dir(0, 0, 1)));
    stage(9);
    int nsec = 0;
    for (TopExp_Explorer ex(sec.Shape(), TopAbs_EDGE); ex.More(); ex.Next()) ++nsec;
    BRepCheck_Analyzer ana(plate);
    stage(10);
    g_last = plate;
    g_probe = BRepPrimAPI_MakeSphere(gp_Pnt(0, 0, 0), 4);
    Bnd_Box bb; BRepBndLib::Add(plate, bb);
    std::printf("rep %d: vol=%.3f tris=%ld dist=%.4f secEdges=%d valid=%d\n",
                rep, props.Mass(), tris, dist.Value(), nsec, (int)ana.IsValid());
  }
  std::printf("total %.2f s\n", now() - t0);
  { const char* n[] = {"box+fillet+holes+chamfer", "spline extrude+sphere fuse", "loft+cut", "pipe+fuse", "shell+common+fuse", "revolve+fuse", "mesh 0.1", "gprop", "extrema", "section", "check"}; double tot = 0; for (int k = 0; k < 11; ++k) tot += g_stage[k];
    for (int k = 0; k < 11; ++k) std::printf("  %-28s %6.3f s %5.1f%%\n", n[k], g_stage[k], 100 * g_stage[k] / tot); }
  // optional second phase: kernel-heavy loops on the last shape
  const char* mode = argc > 2 ? argv[2] : "";
  if (std::strcmp(mode, "mesh") == 0)
  {
    double t1 = now();
    long tris = 0;
    for (int i = 0; i < reps; ++i)
    {
      BRepTools::Clean(g_last);
      BRepMesh_IncrementalMesh mesh(g_last, 0.01, false, 0.1, false);
      tris += countTriangles(g_last);
    }
    std::printf("mesh phase %.2f s (%ld tris)\n", now() - t1, tris);
  }
  else if (std::strcmp(mode, "extrema") == 0)
  {
    double t1 = now();
    double acc = 0;
    for (int i = 0; i < reps * 20; ++i)
    {
      gp_Trsf tr; tr.SetTranslation(gp_Vec(0.37 * i, 0.11 * i, 60 + 0.5 * i));
      TopoDS_Shape probe = BRepBuilderAPI_Transform(g_probe, tr, true).Shape();
      BRepExtrema_DistShapeShape dist(g_last, probe);
      acc += dist.Value();
    }
    std::printf("extrema phase %.2f s (%.3f)\n", now() - t1, acc);
  }
  return 0;
}
