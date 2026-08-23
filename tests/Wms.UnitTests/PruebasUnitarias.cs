using FluentAssertions;
using FluentValidation.TestHelper;
using Wms.Application.Catalogos;
using Wms.Application.Comun;
using Wms.Application.Comun.Operaciones;
using Wms.Application.Comun.Sku;
using Wms.Application.Inventario.AjustarExistencia;
using Wms.Domain.Errores;
using Xunit;

namespace Wms.UnitTests;

public class PruebasAnalizadorSku
{
    private static AnalizadorSku Crear() => new(new ReglaSku(
        1, "DEFAULT_V1", "-", "[A-Z]{4}", 4, "^[A-Z]{4}-[0-9]{4}$"));

    [Fact]
    public void Acepta_un_sku_bien_formado_y_lo_descompone()
    {
        var r = Crear().Analizar("ELEC-0042");
        r.EsValido.Should().BeTrue();
        r.Prefijo.Should().Be("ELEC");
        r.Consecutivo.Should().Be(42);
    }

    [Theory]
    [InlineData("elec-0001")]   // minusculas
    [InlineData("ELEC-1")]      // consecutivo corto
    [InlineData("ELE-0001")]    // prefijo corto
    [InlineData("ELEC-00001")]  // consecutivo largo
    [InlineData("ELEC_0001")]   // separador equivocado
    [InlineData("ELEC0001")]    // sin separador
    [InlineData("")]
    [InlineData(null)]
    public void Rechaza_los_sku_mal_formados(string? sku) =>
        Crear().Analizar(sku).EsValido.Should().BeFalse();

    [Fact]
    public void Obedece_a_la_regla_de_la_base_y_no_a_un_patron_compilado()
    {
        // Misma entrada, regla distinta: el comportamiento cambia sin recompilar.
        var otraRegla = new AnalizadorSku(new ReglaSku(
            2, "CINCO_DIGITOS", "-", "[A-Z]{4}", 5, "^[A-Z]{4}-[0-9]{5}$"));

        Crear().Analizar("ELEC-00042").EsValido.Should().BeFalse();
        otraRegla.Analizar("ELEC-00042").EsValido.Should().BeTrue();
    }
}

public class PruebasHuellaPeticion
{
    private static Dictionary<string, object?> Intencion(int delta = 2, string? motivo = null) => new()
    {
        ["producto_id"] = 12, ["almacen_id"] = 3, ["delta"] = delta,
        ["tipo_movimiento"] = "AJUSTE", ["usuario_id"] = 7, ["motivo"] = motivo
    };

    [Fact]
    public void El_orden_de_las_propiedades_no_altera_la_huella()
    {
        var a = new Dictionary<string, object?>
            { ["producto_id"] = 12, ["almacen_id"] = 3, ["delta"] = 2, ["tipo_movimiento"] = "AJUSTE", ["usuario_id"] = 7 };
        var b = new Dictionary<string, object?>
            { ["usuario_id"] = 7, ["tipo_movimiento"] = "AJUSTE", ["delta"] = 2, ["almacen_id"] = 3, ["producto_id"] = 12 };

        HuellaPeticion.Calcular("/api/inventario/ajustar", a)
            .Should().Be(HuellaPeticion.Calcular("/api/inventario/ajustar", b));
    }

    [Fact]
    public void Editar_el_motivo_NO_cambia_la_huella()
    {
        // Es la regla que evita el WM015 espurio: si el motivo entrara al hash,
        // corregir su texto entre reenvios bloquearia la operacion para siempre
        // y empujaria al usuario a acunar un id nuevo, que si se aplicaria dos
        // veces. Un hash demasiado amplio CAUSA la duplicacion que evita.
        HuellaPeticion.Calcular("/api/inventario/ajustar", Intencion(motivo: "conteo ciclico"))
            .Should().Be(HuellaPeticion.Calcular("/api/inventario/ajustar", Intencion(motivo: "CONTEO CICLICO corregido")));
    }

    [Fact]
    public void Cambiar_la_cantidad_SI_cambia_la_huella()
    {
        HuellaPeticion.Calcular("/api/inventario/ajustar", Intencion(delta: 2))
            .Should().NotBe(HuellaPeticion.Calcular("/api/inventario/ajustar", Intencion(delta: 3)));
    }

    [Fact]
    public void Ausente_nulo_y_vacio_se_normalizan_igual()
    {
        var sinCampo = new Dictionary<string, object?>
            { ["producto_id"] = 12, ["almacen_id"] = 3, ["delta"] = 2, ["tipo_movimiento"] = "AJUSTE", ["usuario_id"] = 7 };
        var conVacio = new Dictionary<string, object?>(sinCampo) { ["motivo"] = "" };

        HuellaPeticion.Calcular("/api/inventario/ajustar", sinCampo)
            .Should().Be(HuellaPeticion.Calcular("/api/inventario/ajustar", conVacio));
    }

    [Fact]
    public void Una_ruta_sin_conjunto_declarado_falla_en_vez_de_adivinar()
    {
        var accion = () => HuellaPeticion.Calcular("/api/ruta/inventada", Intencion());
        accion.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void El_conjunto_del_hash_cubre_las_columnas_del_indice_de_barrera()
    {
        // Invariante normativo: el hash debe ser superconjunto de las columnas
        // de ux_tbl_movimientos_inventario__operacion.
        var campos = HuellaPeticion.CamposPorRuta["/api/inventario/ajustar"];
        campos.Should().Contain(["producto_id", "almacen_id", "tipo_movimiento"]);
        campos.Should().NotContain("motivo");
        campos.Should().NotContain("version_esperada");
    }
}

public class PruebasContextoOperacion
{
    [Fact]
    public void Antepone_el_operador_al_id_acunado_por_el_cliente()
    {
        new ContextoOperacion("ABC123-modal", 7, "ajuste", "/api/x")
            .IdOperacionCompleto.Should().Be("7:ABC123-modal");
    }

    [Fact]
    public void No_duplica_el_prefijo_si_ya_viene_puesto()
    {
        new ContextoOperacion("7:ABC123-modal", 7, "ajuste", "/api/x")
            .IdOperacionCompleto.Should().Be("7:ABC123-modal");
    }
}

public class PruebasMapeoErrores
{
    [Theory]
    [InlineData("WM002", 422)]
    [InlineData("WM013", 409)]
    [InlineData("WM014", 422)]
    [InlineData("WM016", 409)]
    [InlineData("23505", 409)]
    [InlineData("P0002", 404)]
    [InlineData("57014", 499)]
    [InlineData("40001", 409)]
    public void Traduce_cada_sqlstate_a_su_http(string estado, int http) =>
        CodigoWms.Resolver(estado).Http.Should().Be(http);

    [Theory]
    [InlineData("40001", true)]
    [InlineData("40P01", true)]
    [InlineData("55P03", true)]
    [InlineData("WM002", false)]
    [InlineData("WM013", false)]
    [InlineData("23505", false)]
    public void Solo_los_transitorios_del_motor_se_reintentan(string estado, bool esperado) =>
        CodigoWms.EsTransitorio(estado).Should().Be(esperado);

    [Fact]
    public void Un_sqlstate_desconocido_no_se_reintenta_y_es_500() =>
        CodigoWms.Resolver("XX999").Should().Match<CodigoWms.Definicion>(
            d => d.Http == 500 && !d.Reintentable);
}

public class PruebasValidadorAjuste
{
    private readonly ValidadorAjustarExistencia _v = new();

    [Fact]
    public void Rechaza_delta_cero() =>
        _v.TestValidate(new ComandoAjustarExistencia(1, 1, 0, "AJUSTE", null, null))
          .ShouldHaveValidationErrorFor(c => c.Delta);

    [Fact]
    public void Rechaza_tipos_que_pertenecen_al_ciclo_de_la_orden() =>
        _v.TestValidate(new ComandoAjustarExistencia(1, 1, 5, "RESERVA", null, null))
          .ShouldHaveValidationErrorFor(c => c.TipoMovimiento);

    [Fact]
    public void Acepta_un_ajuste_bien_formado() =>
        _v.TestValidate(new ComandoAjustarExistencia(1, 1, -3, "SALIDA", "merma", 4))
          .ShouldNotHaveAnyValidationErrors();
}

public class PruebasPaginado
{
    [Fact]
    public void El_tamano_convenido_es_25() =>
        Pagina<object>.PorPaginaPorOmision.Should().Be(25);

    [Theory]
    [InlineData(null, null, 1, 25, 0)]     // sin parámetros: primera página
    [InlineData(1, 25, 1, 25, 0)]
    [InlineData(3, 25, 3, 25, 50)]         // el salto es (página − 1) × tamaño
    [InlineData(0, 25, 1, 25, 0)]          // página 0 no existe
    [InlineData(-7, 25, 1, 25, 0)]         // ni negativa
    [InlineData(2, 0, 2, 1, 1)]            // un tamaño de 0 dividiría entre cero
    [InlineData(1, 5000, 1, 200, 0)]       // techo: nadie pide la tabla entera
    public void Normaliza_lo_que_llega_por_query_string(
        int? pagina, int? porPagina, int esperadaPagina, int esperadoTamano, int esperadoSalto)
    {
        var (p, pp, salto) = Paginado.Normalizar(pagina, porPagina);
        p.Should().Be(esperadaPagina);
        pp.Should().Be(esperadoTamano);
        salto.Should().Be(esperadoSalto);
    }

    [Fact]
    public void La_ultima_pagina_parcial_cuenta_como_pagina_completa()
    {
        // 137 registros de 25 en 25 son 6 páginas: la sexta trae 12.
        var pagina = new Pagina<int>([1, 2, 3], 137, 6, 25);
        pagina.TotalPaginas.Should().Be(6);
        pagina.HayAnterior.Should().BeTrue();
        pagina.HaySiguiente.Should().BeFalse();
    }

    [Fact]
    public void Un_filtro_sin_resultados_no_tiene_paginas()
    {
        var vacia = Pagina<int>.Vacia(1, 25);
        vacia.Total.Should().Be(0);
        vacia.TotalPaginas.Should().Be(0);
        vacia.HayAnterior.Should().BeFalse();
        vacia.HaySiguiente.Should().BeFalse();
    }
}

public class PruebasAltaCatalogo
{
    private readonly ValidadorAltaCatalogo _v = new();

    private static ComandoAltaCatalogo Cmd(string recurso, params (string, string?)[] campos) =>
        new(recurso, campos.ToDictionary(c => c.Item1, c => c.Item2));

    [Fact]
    public void El_operador_SISTEMA_es_el_uno() =>
        ManejadorAltaCatalogo.UsuarioSistema.Should().Be(1);

    [Theory]
    [InlineData("categorias")]
    [InlineData("almacenes")]
    [InlineData("clientes")]
    [InlineData("usuarios")]
    [InlineData("productos")]
    public void La_regla_cubre_todos_los_catalogos_con_alta(string recurso) =>
        CatalogosPermitidos.Existe(recurso).Should().BeTrue();

    [Fact]
    public void Un_recurso_fuera_de_la_lista_no_tiene_alta() =>
        _v.TestValidate(Cmd("tbl_movimientos_inventario", ("nombre", "x")))
          .ShouldHaveValidationErrorFor(c => c.Recurso);

    [Fact]
    public void Ninguna_definicion_deja_capturar_columnas_que_calcula_el_motor()
    {
        // Es la barrera contra el alta genérica: si un catálogo admitiera
        // 'sku' o 'desactivado_por_usuario_id', la acuñación y la auditoría
        // se podrían falsear desde el cuerpo de la petición.
        string[] prohibidas =
        [
            "id", "sku", "sku_prefijo", "sku_consecutivo", "consecutivo", "consecutivo_sku",
            "es_activo", "desactivado_en", "desactivado_por_usuario_id",
            "version_concurrencia", "creado_en", "actualizado_en",
        ];

        foreach (var nombre in CatalogosPermitidos.Nombres)
        {
            var def = CatalogosPermitidos.Obtener(nombre);
            def.Obligatorios.Concat(def.Opcionales).Should().NotIntersectWith(prohibidas,
                $"el catálogo '{nombre}' no debe aceptar columnas derivadas");
        }
    }

    [Fact]
    public void Rechaza_un_campo_que_no_esta_en_la_lista_blanca() =>
        _v.TestValidate(Cmd("categorias", ("codigo", "ELEC"), ("nombre", "Electrónica"), ("sku", "X")))
          .ShouldHaveValidationErrorFor("sku");

    [Fact]
    public void Exige_los_campos_obligatorios() =>
        _v.TestValidate(Cmd("categorias", ("codigo", "ELEC")))
          .ShouldHaveValidationErrorFor("nombre");

    [Theory]
    [InlineData("elec")]      // minúsculas
    [InlineData("ELE")]       // tres letras
    [InlineData("ELECT")]     // cinco
    [InlineData("EL3C")]      // dígito
    public void El_codigo_de_categoria_es_el_prefijo_del_SKU_y_no_admite_variantes(string codigo) =>
        _v.TestValidate(Cmd("categorias", ("codigo", codigo), ("nombre", "X")))
          .ShouldHaveValidationErrorFor("codigo");

    [Fact]
    public void Acepta_una_categoria_bien_formada() =>
        _v.TestValidate(Cmd("categorias", ("codigo", "ELEC"), ("nombre", "Electrónica")))
          .ShouldNotHaveAnyValidationErrors();

    [Fact]
    public void Acepta_un_almacen_bien_formado() =>
        _v.TestValidate(Cmd("almacenes", ("codigo", "ALM-004"), ("nombre", "Norte")))
          .ShouldNotHaveAnyValidationErrors();

    [Fact]
    public void Rechaza_un_codigo_de_almacen_de_longitud_distinta() =>
        _v.TestValidate(Cmd("almacenes", ("codigo", "ALM-0004"), ("nombre", "Norte")))
          .ShouldHaveValidationErrorFor("codigo");

    [Fact]
    public void Un_operador_nuevo_no_puede_nacer_con_rol_arbitrario() =>
        _v.TestValidate(Cmd("usuarios", ("nombre", "Ana"), ("rol", "ADMIN")))
          .ShouldHaveValidationErrorFor("rol");

    [Fact]
    public void El_precio_del_producto_admite_a_lo_sumo_dos_decimales() =>
        _v.TestValidate(Cmd("productos", ("categoria_id", "1"), ("nombre", "Cable"),
                            ("precio_unitario", "10.999")))
          .ShouldHaveValidationErrorFor("precio_unitario");
}

public class PruebasEdicionCatalogo
{
    private readonly ValidadorEditarCatalogo _v = new();

    private static ComandoEditarCatalogo Cmd(string recurso, long version, params (string, string?)[] campos) =>
        new(recurso, 7, campos.ToDictionary(c => c.Item1, c => c.Item2), version);

    [Fact]
    public void Acepta_una_correccion_bien_formada() =>
        _v.TestValidate(Cmd("clientes", 3, ("telefono", "55-1234-5678")))
          .ShouldNotHaveAnyValidationErrors();

    [Fact]
    public void La_version_esperada_es_obligatoria() =>
        _v.TestValidate(Cmd("clientes", 0, ("telefono", "55-1234-5678")))
          .ShouldHaveValidationErrorFor(c => c.VersionEsperada);

    [Fact]
    public void Rechaza_una_correccion_sin_campos() =>
        _v.TestValidate(new ComandoEditarCatalogo("clientes", 7, [], 3))
          .ShouldHaveValidationErrorFor(c => c.Campos);

    [Fact]
    public void Rechaza_un_catalogo_desconocido() =>
        _v.TestValidate(Cmd("movimientos", 1, ("nombre", "x")))
          .ShouldHaveValidationErrorFor(c => c.Recurso);

    [Theory]
    [InlineData("clientes", "codigo")]              // generado a partir del consecutivo
    [InlineData("usuarios", "codigo")]              // idem
    [InlineData("productos", "sku")]                // acunado y congelado
    [InlineData("productos", "sku_prefijo")]
    [InlineData("clientes", "es_activo")]           // la vigencia tiene su propio endpoint
    [InlineData("clientes", "desactivado_en")]      // el sello lo pone el motor
    [InlineData("clientes", "version_concurrencia")]
    [InlineData("categorias", "consecutivo_sku")]
    public void Ninguna_columna_derivada_se_puede_escribir_desde_la_edicion(string recurso, string campo) =>
        _v.TestValidate(Cmd(recurso, 1, (campo, "lo que sea")))
          .ShouldHaveValidationErrorFor(campo);

    [Fact]
    public void Un_obligatorio_no_se_puede_vaciar() =>
        _v.TestValidate(Cmd("clientes", 1, ("nombre", "  ")))
          .ShouldHaveValidationErrorFor("nombre");

    [Fact]
    public void Las_reglas_de_formato_valen_igual_que_en_el_alta() =>
        _v.TestValidate(Cmd("almacenes", 1, ("codigo", "ALM-0004")))
          .ShouldHaveValidationErrorFor("codigo");

    [Fact]
    public void El_rol_se_deja_capturar_y_el_motor_decide_quien_puede() =>
        // La API no repite la restriccion: el trigger la impone con WM021.
        _v.TestValidate(Cmd("usuarios", 1, ("rol", "SUPERVISOR")))
          .ShouldNotHaveAnyValidationErrors();

    [Fact]
    public void Recategorizar_un_producto_es_una_edicion_valida() =>
        _v.TestValidate(Cmd("productos", 1, ("categoria_id", "4")))
          .ShouldNotHaveAnyValidationErrors();

    [Fact]
    public void Todo_campo_editable_es_capturable_al_dar_de_alta_o_esta_declarado()
    {
        // Editar no puede abrir columnas que el alta ni siquiera ofrece: seria
        // una segunda lista blanca creciendo por su cuenta.
        foreach (var nombre in CatalogosPermitidos.Nombres)
        {
            var def = CatalogosPermitidos.Obtener(nombre);
            var capturables = def.Obligatorios.Concat(def.Opcionales).ToHashSet();
            def.Editables.Should().BeSubsetOf(capturables,
                $"el catálogo '{nombre}' no debe permitir editar lo que no se puede capturar");
        }
    }

    [Fact]
    public void Cada_catalogo_declara_como_expresa_su_vigencia()
    {
        foreach (var nombre in CatalogosPermitidos.Nombres)
        {
            var v = CatalogosPermitidos.Obtener(nombre).Vigencia;
            v.Columna.Should().NotBeNullOrWhiteSpace();
            v.TipoSql.Should().BeOneOf("boolean", "text");
            v.Vigente.Should().NotBe(v.NoVigente);
        }
        // La excepcion declarada: productos usa estatus, no es_activo.
        CatalogosPermitidos.Obtener("productos").Vigencia.Columna.Should().Be("estatus");
        CatalogosPermitidos.Obtener("clientes").Vigencia.Columna.Should().Be("es_activo");
    }
}
