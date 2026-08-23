using System.Text.RegularExpressions;
using FluentValidation;
using Microsoft.Extensions.Caching.Memory;
using Wms.Api.Endpoints;
using Wms.Api.Middleware;
using Wms.Api.Servicios;
using Wms.Application.Abstracciones;
using Wms.Application.Comun.Operaciones;
using Wms.Application.Inventario.AjustarExistencia;
using Wms.Domain.Errores;
using Wms.Infrastructure.Persistencia;

// Postgres devuelve snake_case; Dapper lo empareja con las propiedades
// PascalCase de los records sin necesidad de alias en el SQL.
Dapper.DefaultTypeMap.MatchNamesWithUnderscores = true;

var builder = WebApplication.CreateBuilder(args);

var cadena = builder.Configuration.GetConnectionString("Wms")
             ?? Environment.GetEnvironmentVariable("WMS_CONEXION")
             ?? "Host=localhost;Port=5432;Database=wms;Username=postgres;Password=verif";

builder.Services.AddSingleton<IFabricaConexion>(_ => new FabricaConexion(cadena));
builder.Services.AddSingleton<IServicioIdempotencia>(_ => new ServicioIdempotencia(cadena));
builder.Services.AddMemoryCache();
builder.Services.AddSingleton<Wms.Application.Inventario.Exportar.ExportadorInventario>();
builder.Services.AddSingleton<IRepositorioReglasSku>(sp =>
    new RepositorioReglasSku(cadena, sp.GetRequiredService<IMemoryCache>()));

builder.Services.AddMediatR(cfg =>
    cfg.RegisterServicesFromAssemblyContaining<ComandoAjustarExistencia>());
builder.Services.AddValidatorsFromAssemblyContaining<ValidadorAjustarExistencia>();

builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<EjecutorIdempotente>();

// El contexto de operacion se resuelve por peticion desde los encabezados.
builder.Services.AddScoped(sp =>
    ContextoDesdeEncabezados(sp.GetRequiredService<IHttpContextAccessor>().HttpContext!));

// La migracion 0003 programa el barrido con pg_cron cuando existe; la imagen
// que usamos no lo trae, asi que la API es el «externamente» que ese aviso
// pedia. Sin esto, una operacion abandonada bloquea su id para siempre.
builder.Services.AddSingleton<IHostedService>(sp =>
    new BarridoOperaciones(cadena, sp.GetRequiredService<ILogger<BarridoOperaciones>>()));

builder.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod()
    .WithExposedHeaders("Retry-After")));

var app = builder.Build();
app.UseCors();
app.UseMiddleware<ManejadorExcepciones>();
Rutas.Mapear(app);
app.Run();

// ---------------------------------------------------------------------
//  Encabezados del protocolo de operacion
// ---------------------------------------------------------------------
static ContextoOperacion ContextoDesdeEncabezados(HttpContext http)
{
    // Solo las rutas mutantes exigen contexto; las consultas no lo necesitan.
    var esMutante = HttpMethods.IsPost(http.Request.Method)
                 || HttpMethods.IsPut(http.Request.Method)
                 || HttpMethods.IsPatch(http.Request.Method)
                 || HttpMethods.IsDelete(http.Request.Method);

    if (!esMutante)
        return new ContextoOperacion("0:consulta-sin-operacion", 0, "consulta", http.Request.Path);

    // La importacion es la unica ruta mutante que NO toma su identidad del
    // encabezado: la toma del CONTENIDO del archivo (ver ManejadorImportar).
    // Exigir un id acunado por el cliente aqui seria pedirle justo lo que
    // volveria a permitir la doble aplicacion al reintentar.
    var esImportacion = http.Request.Path.StartsWithSegments("/api/importacion");

    var id = http.Request.Headers["X-Operation-Id"].ToString();
    if (esImportacion && string.IsNullOrWhiteSpace(id)) id = "derivado-del-archivo";
    var usuario = http.Request.Headers["X-Usuario-Id"].ToString();
    var alcance = http.Request.Headers["X-Scope"].ToString();

    if (string.IsNullOrWhiteSpace(id))
        throw new ExcepcionWms("WM012", 400, "Falta el encabezado X-Operation-Id.",
            "Debe acunarse UNA vez por intencion del usuario y reutilizarse en cada reenvio.");

    if (!long.TryParse(usuario, out var usuarioId) || usuarioId <= 0)
        throw new ExcepcionWms("WM014", 422, "Falta el encabezado X-Usuario-Id o no es valido.",
            "Ninguna mutacion de inventario puede ser anonima.");

    // El ':' queda reservado como separador del prefijo de operador, que
    // antepone el SERVIDOR: asi dos operadores nunca colisionan.
    if (!Regex.IsMatch(id, "^[A-Za-z0-9._-]{8,108}$"))
        throw new ExcepcionWms("WM012", 400, "X-Operation-Id invalido.",
            "Debe medir entre 8 y 108 caracteres de [A-Za-z0-9._-]; ':' esta reservado.");

    if (string.IsNullOrWhiteSpace(alcance))
        alcance = http.Request.Path.Value ?? "desconocido";

    return new ContextoOperacion(id, usuarioId, alcance, http.Request.Path.Value ?? "/");
}

public partial class Program;
