namespace Wms.Application.Comun;

/// <summary>
/// Página de resultados. El total viaja con los elementos porque la interfaz
/// muestra «página X de N», y calcular N exige el conteo de todo el conjunto
/// filtrado.
///
/// El conteo se obtiene con `count(*) over()` en la MISMA consulta, no en una
/// segunda: dos consultas separadas pueden ver estados distintos de la tabla y
/// producir un total que no corresponde a las filas devueltas.
///
/// Se usa LIMIT/OFFSET y no keyset porque «página 37 de 50» requiere saltar a
/// una posición arbitraria, que es justo lo que el keyset no permite. La
/// contrapartida es que el OFFSET profundo se degrada; con los volúmenes de
/// este sistema no compensa el cambio, y queda documentado.
/// </summary>
public sealed record Pagina<T>(IReadOnlyList<T> Elementos, long Total, int NumeroPagina, int PorPagina)
{
    public const int PorPaginaPorOmision = 25;

    public int TotalPaginas => PorPagina <= 0 ? 0 : (int)Math.Ceiling(Total / (double)PorPagina);
    public bool HayAnterior => NumeroPagina > 1;
    public bool HaySiguiente => NumeroPagina < TotalPaginas;

    public static Pagina<T> Vacia(int pagina, int porPagina) => new([], 0, pagina, porPagina);
}

/// <summary>Normaliza los parámetros que llegan por query string.</summary>
public static class Paginado
{
    public const int MaximoPorPagina = 200;

    public static (int Pagina, int PorPagina, int Salto) Normalizar(int? pagina, int? porPagina)
    {
        var p = Math.Max(pagina ?? 1, 1);
        var pp = Math.Clamp(porPagina ?? Pagina<object>.PorPaginaPorOmision, 1, MaximoPorPagina);
        return (p, pp, (p - 1) * pp);
    }
}
