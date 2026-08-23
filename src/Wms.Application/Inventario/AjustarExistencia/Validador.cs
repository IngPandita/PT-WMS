using FluentValidation;

namespace Wms.Application.Inventario.AjustarExistencia;

public sealed class ValidadorAjustarExistencia : AbstractValidator<ComandoAjustarExistencia>
{
    private static readonly string[] TiposPermitidos = ["ENTRADA", "SALIDA", "AJUSTE", "IMPORTACION"];

    public ValidadorAjustarExistencia()
    {
        RuleFor(c => c.ProductoId).GreaterThan(0);
        RuleFor(c => c.AlmacenId).GreaterThan(0);
        RuleFor(c => c.Delta).NotEqual(0)
            .WithMessage("El delta de un ajuste no puede ser cero.");
        RuleFor(c => c.TipoMovimiento).Must(t => TiposPermitidos.Contains(t))
            .WithMessage("El tipo debe ser ENTRADA, SALIDA, AJUSTE o IMPORTACION. " +
                         "RESERVA, LIBERACION y EMBARQUE los produce el ciclo de la orden, no un ajuste.");
        RuleFor(c => c.Motivo).MaximumLength(500);
    }
}
