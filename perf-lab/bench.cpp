// Micro-benchmark of TKMath hot kernels used by CadQuery workloads
// (BSpline evaluation, knot insertion, degree elevation, resolution).
// Built twice against libTKMath/libTKernel: exceptions ON vs No_Exception.
#include <BSplCLib.hxx>
#include <BSplCLib_Cache.hxx>
#include <BSplSLib.hxx>
#include <BSplSLib_Cache.hxx>
#include <PLib.hxx>
#include <NCollection_Array1.hxx>
#include <NCollection_Array2.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>
#include <math_Matrix.hxx>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>
#include <algorithm>

static volatile double g_sink = 0.0;

template <class F>
static double bench(const char* name, F&& f, int reps, double ops)
{
  double best = 1e300;
  for (int r = 0; r < reps; ++r)
  {
    auto t0 = std::chrono::steady_clock::now();
    f();
    auto t1 = std::chrono::steady_clock::now();
    best = std::min(best, std::chrono::duration<double>(t1 - t0).count());
  }
  std::printf("%-22s %10.1f ns/op\n", name, best / ops * 1e9);
  return best;
}

// Uniform clamped knot vector: NbPoles poles, degree Deg.
static void makeKnots(int nbPoles, int deg, NCollection_Array1<double>& knots, NCollection_Array1<int>& mults)
{
  int nbKnots = nbPoles - deg + 1;
  knots.Resize(1, nbKnots, false);
  mults.Resize(1, nbKnots, false);
  for (int i = 1; i <= nbKnots; ++i)
  {
    knots(i) = double(i - 1) / (nbKnots - 1);
    mults(i) = (i == 1 || i == nbKnots) ? deg + 1 : 1;
  }
}

int main(int argc, char** argv)
{
  const char* only = argc > 1 ? argv[1] : nullptr;
  auto want = [&](const char* n) { return !only || std::strcmp(only, n) == 0; };

  // ---------------- surface ----------------
  const int nU = 20, nV = 20, dU = 3, dV = 3;
  NCollection_Array2<gp_Pnt> sPoles(1, nU, 1, nV);
  for (int i = 1; i <= nU; ++i)
    for (int j = 1; j <= nV; ++j)
      sPoles(i, j) = gp_Pnt(i, j, std::sin(0.5 * i) * std::cos(0.3 * j));
  NCollection_Array1<double> uK, vK;
  NCollection_Array1<int>    uM, vM;
  makeKnots(nU, dU, uK, uM);
  makeKnots(nV, dV, vK, vM);
  NCollection_Array1<double> uFK(1, BSplCLib::KnotSequenceLength(uM, dU, false));
  NCollection_Array1<double> vFK(1, BSplCLib::KnotSequenceLength(vM, dV, false));
  BSplCLib::KnotSequence(uK, uM, dU, false, uFK);
  BSplCLib::KnotSequence(vK, vM, dV, false, vFK);

  const int G = 300; // evaluation grid
  if (want("surf_D0"))
    bench("surf_D0", [&] {
      double s = 0;
      gp_Pnt p;
      for (int a = 0; a < G; ++a)
        for (int b = 0; b < G; ++b)
        {
          double u = (a + 0.5) / G, v = (b + 0.5) / G;
          BSplSLib::D0(u, v, 0, 0, sPoles, nullptr, uK, vK, &uM, &vM, dU, dV, false, false, false, false, p);
          s += p.X();
        }
      g_sink = s;
    }, 5, double(G) * G);

  if (want("surf_D1"))
    bench("surf_D1", [&] {
      double s = 0;
      gp_Pnt p; gp_Vec du, dv;
      for (int a = 0; a < G; ++a)
        for (int b = 0; b < G; ++b)
        {
          double u = (a + 0.5) / G, v = (b + 0.5) / G;
          BSplSLib::D1(u, v, 0, 0, sPoles, nullptr, uK, vK, &uM, &vM, dU, dV, false, false, false, false, p, du, dv);
          s += p.X() + du.Y();
        }
      g_sink = s;
    }, 5, double(G) * G);

  if (want("surf_cache_D0"))
    bench("surf_cache_D0", [&] {
      BSplSLib_Cache cache(dU, false, uFK, dV, false, vFK, nullptr);
      double s = 0;
      gp_Pnt p;
      for (int a = 0; a < G; ++a)
        for (int b = 0; b < G; ++b)
        {
          double u = (a + 0.5) / G, v = (b + 0.5) / G;
          if (!cache.IsCacheValid(u, v))
            cache.BuildCache(u, v, uFK, vFK, sPoles, nullptr);
          cache.D0(u, v, p);
          s += p.X();
        }
      g_sink = s;
    }, 5, double(G) * G);

  if (want("surf_cache_D1"))
    bench("surf_cache_D1", [&] {
      BSplSLib_Cache cache(dU, false, uFK, dV, false, vFK, nullptr);
      double s = 0;
      gp_Pnt p; gp_Vec du, dv;
      for (int a = 0; a < G; ++a)
        for (int b = 0; b < G; ++b)
        {
          double u = (a + 0.5) / G, v = (b + 0.5) / G;
          if (!cache.IsCacheValid(u, v))
            cache.BuildCache(u, v, uFK, vFK, sPoles, nullptr);
          cache.D1(u, v, p, du, dv);
          s += p.X() + du.Y();
        }
      g_sink = s;
    }, 5, double(G) * G);

  // ---------------- rational degree-6 surface (runtime PLib path, dim 28) ----------------
  {
    const int n6 = 12, d6 = 6;
    NCollection_Array2<gp_Pnt>  p6(1, n6, 1, n6);
    NCollection_Array2<double>  w6(1, n6, 1, n6);
    for (int i = 1; i <= n6; ++i)
      for (int j = 1; j <= n6; ++j)
      {
        p6(i, j) = gp_Pnt(i, j, std::sin(0.4 * i) * std::cos(0.3 * j));
        w6(i, j) = 1.0 + 0.2 * std::sin(i + j);
      }
    NCollection_Array1<double> k6; NCollection_Array1<int> m6;
    makeKnots(n6, d6, k6, m6);
    NCollection_Array1<double> fk6(1, BSplCLib::KnotSequenceLength(m6, d6, false));
    BSplCLib::KnotSequence(k6, m6, d6, false, fk6);
    if (want("surf6r_cache_D0"))
      bench("surf6r_cache_D0", [&] {
        BSplSLib_Cache cache(d6, false, fk6, d6, false, fk6, &w6);
        double s = 0; gp_Pnt p;
        for (int a = 0; a < G; ++a)
          for (int b = 0; b < G; ++b)
          {
            double u = (a + 0.5) / G, v = (b + 0.5) / G;
            if (!cache.IsCacheValid(u, v)) cache.BuildCache(u, v, fk6, fk6, p6, &w6);
            cache.D0(u, v, p);
            s += p.X();
          }
        g_sink = s;
      }, 5, double(G) * G);
    if (want("surf6r_cache_D1"))
      bench("surf6r_cache_D1", [&] {
        BSplSLib_Cache cache(d6, false, fk6, d6, false, fk6, &w6);
        double s = 0; gp_Pnt p; gp_Vec du, dv;
        for (int a = 0; a < G; ++a)
          for (int b = 0; b < G; ++b)
          {
            double u = (a + 0.5) / G, v = (b + 0.5) / G;
            if (!cache.IsCacheValid(u, v)) cache.BuildCache(u, v, fk6, fk6, p6, &w6);
            cache.D1(u, v, p, du, dv);
            s += p.X() + du.Y();
          }
        g_sink = s;
      }, 5, double(G) * G);
    if (want("surf6r_build"))
      bench("surf6r_build", [&] {
        BSplSLib_Cache cache(d6, false, fk6, d6, false, fk6, &w6);
        double s = 0; gp_Pnt p;
        for (int a = 0; a < 20000; ++a)
        {
          double u = ((a * 7) % 97 + 0.5) / 97.0, v = ((a * 13) % 89 + 0.5) / 89.0;
          cache.BuildCache(u, v, fk6, fk6, p6, &w6);
          cache.D0(u, v, p);
          s += p.X();
        }
        g_sink = s;
      }, 5, 20000);
  }

  // ---------------- curve ----------------
  const int nC = 50, dC = 3;
  NCollection_Array1<gp_Pnt> cPoles(1, nC);
  for (int i = 1; i <= nC; ++i)
    cPoles(i) = gp_Pnt(i, std::sin(0.3 * i), std::cos(0.2 * i));
  NCollection_Array1<double> cK; NCollection_Array1<int> cM;
  makeKnots(nC, dC, cK, cM);
  NCollection_Array1<double> cFK(1, BSplCLib::KnotSequenceLength(cM, dC, false));
  BSplCLib::KnotSequence(cK, cM, dC, false, cFK);

  const int NE = 200000;
  if (want("curve_D0"))
    bench("curve_D0", [&] {
      double s = 0; gp_Pnt p;
      for (int a = 0; a < NE; ++a)
      {
        BSplCLib::D0((a + 0.5) / NE, 0, dC, false, cPoles, nullptr, cK, &cM, p);
        s += p.X();
      }
      g_sink = s;
    }, 5, NE);

  if (want("curve_D1"))
    bench("curve_D1", [&] {
      double s = 0; gp_Pnt p; gp_Vec v;
      for (int a = 0; a < NE; ++a)
      {
        BSplCLib::D1((a + 0.5) / NE, 0, dC, false, cPoles, nullptr, cK, &cM, p, v);
        s += p.X() + v.Y();
      }
      g_sink = s;
    }, 5, NE);

  if (want("curve_cache_D1"))
    bench("curve_cache_D1", [&] {
      BSplCLib_Cache cache(dC, false, cFK, cPoles, nullptr);
      double s = 0; gp_Pnt p; gp_Vec v;
      for (int a = 0; a < NE; ++a)
      {
        double u = (a + 0.5) / NE;
        if (!cache.IsCacheValid(u))
          cache.BuildCache(u, cFK, cPoles, nullptr);
        cache.D1(u, p, v);
        s += p.X() + v.Y();
      }
      g_sink = s;
    }, 5, NE);

  if (want("resolution"))
    bench("resolution", [&] {
      double s = 0, tol;
      for (int a = 0; a < 2000; ++a)
      {
        BSplCLib::Resolution(cPoles, nullptr, nC, cFK, dC, 1e-7 * (a + 1), tol);
        s += tol;
      }
      g_sink = s;
    }, 5, 2000);

  if (want("increase_degree"))
    bench("increase_degree", [&] {
      double s = 0;
      const int newDeg = 5;
      int nbK = cK.Length();
      int nbNewK = BSplCLib::IncreaseDegreeCountKnots(dC, newDeg, false, cM);
      int nbNewP = nC + (newDeg - dC) * (nbK - 1);
      NCollection_Array1<gp_Pnt> nP(1, nbNewP);
      NCollection_Array1<double> nK(1, nbNewK);
      NCollection_Array1<int>    nM(1, nbNewK);
      for (int a = 0; a < 2000; ++a)
      {
        BSplCLib::IncreaseDegree(dC, newDeg, false, cPoles, nullptr, cK, cM, nP, nullptr, nK, nM);
        s += nP(nbNewP / 2).X();
      }
      g_sink = s;
    }, 5, 2000);

  if (want("insert_knots"))
    bench("insert_knots", [&] {
      double s = 0;
      NCollection_Array1<double> addK(1, 10);
      for (int i = 1; i <= 10; ++i) addK(i) = (i - 0.5) / 10.0 + 0.013;
      int nbNewP, nbNewK;
      BSplCLib::PrepareInsertKnots(dC, false, cK, cM, addK, nullptr, nbNewP, nbNewK, 1e-9, true);
      NCollection_Array1<gp_Pnt> nP(1, nbNewP);
      NCollection_Array1<double> nK(1, nbNewK);
      NCollection_Array1<int>    nM(1, nbNewK);
      for (int a = 0; a < 5000; ++a)
      {
        BSplCLib::InsertKnots(dC, false, cPoles, nullptr, cK, cM, addK, nullptr, nP, nullptr, nK, nM, 1e-9, true);
        s += nP(nbNewP / 2).X();
      }
      g_sink = s;
    }, 5, 5000);

  if (want("eval_basis"))
    bench("eval_basis", [&] {
      double s = 0;
      math_Matrix basis(1, 2, 1, dC + 1);
      int first;
      for (int a = 0; a < 200000; ++a)
      {
        BSplCLib::EvalBsplineBasis(1, dC + 1, cFK, (a + 0.5) / 200000, first, basis, false);
        s += basis(1, 1) + basis(2, 2);
      }
      g_sink = s;
    }, 5, 200000);

  // ---------------- PLib ----------------
  for (int dim : {3, 12, 24, 28, 40})
  {
    char name[32];
    std::snprintf(name, sizeof name, "eval_poly_dim%d", dim);
    if (!want(name)) continue;
    const int deg = 5;
    std::vector<double> coeffs((deg + 1) * dim), res(dim);
    for (size_t i = 0; i < coeffs.size(); ++i) coeffs[i] = std::sin(0.1 * i);
    bench(name, [&] {
      double s = 0;
      for (int a = 0; a < 1000000; ++a)
      {
        PLib::NoDerivativeEvalPolynomial((a & 1023) / 1024.0, deg, dim, deg * dim, coeffs[0], res[0]);
        s += res[0] + res[dim - 1];
      }
      g_sink = s;
    }, 5, 1000000);
  }

  return 0;
}
