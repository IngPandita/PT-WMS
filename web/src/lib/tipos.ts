export interface FilaTablero {
  productoId: number; almacenId: number; productoSku: string; productoNombre: string
  productoPrecio: number; productoEstatus: string
  categoriaCodigo: string; categoriaNombre: string
  almacenCodigo: string; almacenNombre: string; localizador: string
  cantidadFisica: number; cantidadReservada: number; cantidadDisponible: number
  cantidadMinima: number; esExistenciaBaja: boolean
  versionConcurrencia: number; actualizadoEn: string
}

export interface FilaMovimiento {
  id: number; uuidMovimiento: string; creadoEn: string
  tipoMovimiento: string; tipoOrigen: string
  productoSku: string; productoNombre: string; almacenCodigo: string
  deltaFisica: number; fisicaAntes: number; fisicaDespues: number
  deltaReservada: number; reservadaAntes: number; reservadaDespues: number
  estado: string; ordenFolio: string | null; clienteNombre: string | null
  idOperacion: string; motivo: string | null
  usuarioId: number; usuarioCodigo: string; usuarioNombre: string; usuarioVigente: boolean
  productoId: number; almacenId: number
  estaDesactivado: boolean; reversaId: number | null; desactivadoEn: string | null
  desactivadoPorNombre: string | null; motivoDesactivacion: string | null
  movimientoRevertidoId: number | null; esReversa: boolean
}

export interface FilaOrden {
  id: number; folio: string; estatus: string; montoTotal: number
  clienteCodigo: string; clienteNombre: string; clienteVigente: boolean
  almacenCodigo: string; almacenNombre: string
  partidas: number; unidades: number
  confirmadoEn: string | null; enviadoEn: string | null; canceladoEn: string | null
  motivoCancelacion: string | null; notas: string | null
  creadoPorCodigo: string; creadoPorNombre: string
  versionConcurrencia: number; creadoEn: string
}

export interface FilaPartida {
  id: number; ordenId: number; productoId: number
  productoSku: string; productoNombre: string
  cantidad: number; precioUnitarioHistorico: number; importeLinea: number
  productoPrecioVigente: number; localizador: string
}

export interface Indicadores {
  operacion: Record<string, number>
  porAlmacen: Record<string, unknown>[]
  serieDiaria: Record<string, unknown>[]
  aportacionPorUsuario: Record<string, unknown>[]
  mayorDemanda: Record<string, unknown>[]
  existenciaInsuficiente: Record<string, unknown>[]
  diasDemanda: number
}

export interface Usuario { id: number; codigo: string; nombre: string; rol: string; es_activo: boolean }
export interface Almacen { id: number; codigo: string; nombre: string; es_activo: boolean }
export interface Categoria { id: number; codigo: string; nombre: string; descripcion: string | null; es_activo: boolean }
export interface Cliente { id: number; codigo: string; nombre: string; es_activo: boolean }
export interface Producto { id: number; sku: string; nombre: string; precio_unitario: number; estatus: string }

export interface ResultadoImportacion {
  loteId: number; idOperacion: string; estatus: string; modo: string
  renglonesTotal: number; renglonesOk: number; renglonesError: number
  renglonesOmitidos: number; fueReanudacion: boolean
  detalle: {
    numero: number; estatus: string; accion: string | null
    codigoError: string | null; mensaje: string | null
    sku: string | null; cantidadAplicada: number | null
  }[]
}

export interface ProductoEncontrado {
  id: number; sku: string; nombre: string; categoriaNombre: string
  precioUnitario: number; estatus: string; cantidadDisponible: number | null
}
