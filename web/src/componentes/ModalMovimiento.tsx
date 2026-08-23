import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, Ban } from 'lucide-react'
import { ErrorApi, acunarIdOperacion, peticion } from '../lib/api'
import type { FilaMovimiento } from '../lib/tipos'
import { Insignia, Modal, tonoEstatus, usarAvisos } from './Base'

/** Solo el operador SISTEMA puede desactivar. El backend lo impone igual. */
export const USUARIO_SISTEMA = 1

const FECHA = new Intl.DateTimeFormat('es-MX', { dateStyle: 'full', timeStyle: 'medium' })

function Dato({ etiqueta, children }: { etiqueta: string; children: React.ReactNode }) {
  return (
    <div>
      <p className="etiqueta">{etiqueta}</p>
      <p className="mt-0.5 text-sm text-tinta-800">{children}</p>
    </div>
  )
}

export function ModalMovimiento({
  movimiento, usuarioId, alCerrar,
}: { movimiento: FilaMovimiento; usuarioId: number; alCerrar: () => void }) {
  const avisar = usarAvisos()
  const clienteQuery = useQueryClient()
  const [confirmando, setConfirmando] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [idOperacion] = useState(() => acunarIdOperacion('desactivarmov'))

  // Se relee el detalle completo: la fila del listado trae lo justo.
  const { data: detalle } = useQuery({
    queryKey: ['movimiento', movimiento.id],
    queryFn: () => peticion<Record<string, unknown>>(`/api/inventario/movimientos/${movimiento.id}`),
  })

  const esSistema = usuarioId === USUARIO_SISTEMA
  const yaDesactivado = movimiento.estaDesactivado
  const esDeOrden = movimiento.tipoOrigen === 'ORDEN'
  const puedeDesactivar = esSistema && !yaDesactivado && !esDeOrden && !movimiento.esReversa

  const desactivar = useMutation({
    mutationFn: () => peticion(`/api/inventario/movimientos/${movimiento.id}/desactivar`, {
      metodo: 'POST', cuerpo: { motivo },
      idOperacion, usuarioId, alcance: `mov:desactivar:${movimiento.id}`,
    }),
    onSuccess: () => {
      avisar({
        tono: 'exito',
        texto: `Movimiento #${movimiento.id} desactivado`,
        detalle: 'Se registró un movimiento de reversa; el original queda intacto en la bitácora.',
      })
      clienteQuery.invalidateQueries({ queryKey: ['movimientos'] })
      clienteQuery.invalidateQueries({ queryKey: ['inventario'] })
      clienteQuery.invalidateQueries({ queryKey: ['indicadores'] })
      alCerrar()
    },
    onError: (e: ErrorApi) => avisar({ tono: 'error', texto: e.titulo, detalle: e.detalle ?? undefined }),
  })

  return (
    <Modal
      abierto alCerrar={alCerrar}
      titulo={`Movimiento #${movimiento.id}`}
      descripcion={movimiento.uuidMovimiento}
      pie={
        <>
          <button className="boton-secundario" onClick={alCerrar}>Cerrar</button>
          {puedeDesactivar && !confirmando && (
            <button className="boton bg-rose-600 text-white hover:bg-rose-700"
                    onClick={() => setConfirmando(true)}>
              <Ban className="h-3.5 w-3.5" /> Desactivar
            </button>
          )}
        </>
      }
    >
      <div className="space-y-4">
        <div className="flex flex-wrap items-center gap-2">
          <Insignia tono={movimiento.deltaFisica > 0 ? 'exito' : movimiento.deltaFisica < 0 ? 'peligro' : 'info'}>
            {movimiento.tipoMovimiento.toLowerCase()}
          </Insignia>
          <Insignia tono={tonoEstatus[movimiento.estado] ?? 'neutro'}>
            {movimiento.estado.toLowerCase()}
          </Insignia>
          {movimiento.esReversa && <Insignia tono="info">es una reversa</Insignia>}
        </div>

        {yaDesactivado && (
          <div className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2">
            <p className="text-sm font-medium text-amber-800">Movimiento desactivado</p>
            <p className="mt-0.5 text-2xs text-amber-700">
              Desactivado por {movimiento.desactivadoPorNombre} el{' '}
              {movimiento.desactivadoEn && FECHA.format(new Date(movimiento.desactivadoEn))}.
              {movimiento.motivoDesactivacion && ` Motivo: ${movimiento.motivoDesactivacion}`}
            </p>
            <p className="mt-1 text-2xs text-amber-700">
              Su información histórica permanece intacta: la desactivación se registró como un
              movimiento de reversa (#{movimiento.reversaId}), no borrando ni editando éste.
            </p>
          </div>
        )}

        <div className="grid grid-cols-2 gap-3">
          <Dato etiqueta="Producto">{movimiento.productoNombre}</Dato>
          <Dato etiqueta="SKU"><span className="font-mono text-2xs">{movimiento.productoSku}</span></Dato>
          <Dato etiqueta="Almacén"><span className="font-mono text-2xs">{movimiento.almacenCodigo}</span></Dato>
          <Dato etiqueta="Tipo de origen">{movimiento.tipoOrigen.toLowerCase()}</Dato>
          <Dato etiqueta="Cantidad (físico)">
            <span className="tabular-nums">
              {movimiento.deltaFisica > 0 ? '+' : ''}{movimiento.deltaFisica}
            </span>
            <span className="ml-2 text-2xs text-tinta-500">
              {movimiento.fisicaAntes} → {movimiento.fisicaDespues}
            </span>
          </Dato>
          <Dato etiqueta="Cantidad (reservado)">
            <span className="tabular-nums">
              {movimiento.deltaReservada > 0 ? '+' : ''}{movimiento.deltaReservada}
            </span>
            <span className="ml-2 text-2xs text-tinta-500">
              {movimiento.reservadaAntes} → {movimiento.reservadaDespues}
            </span>
          </Dato>
          <Dato etiqueta="Usuario">
            {movimiento.usuarioNombre}
            {!movimiento.usuarioVigente && (
              <span className="ml-1 text-2xs text-tinta-400">(dado de baja)</span>
            )}
          </Dato>
          <Dato etiqueta="Fecha y hora">
            <span className="text-2xs tabular-nums">{FECHA.format(new Date(movimiento.creadoEn))}</span>
          </Dato>
          <div className="col-span-2">
            <Dato etiqueta="Identificador de operación">
              <span className="font-mono text-2xs">{movimiento.idOperacion}</span>
            </Dato>
          </div>
          {movimiento.ordenFolio && (
            <Dato etiqueta="Orden">{movimiento.ordenFolio} · {movimiento.clienteNombre}</Dato>
          )}
          {movimiento.motivo && <Dato etiqueta="Motivo">{movimiento.motivo}</Dato>}
          {detalle?.lote_archivo != null && (
            <Dato etiqueta="Lote de importación">{String(detalle.lote_archivo)}</Dato>
          )}
        </div>

        {esSistema && !yaDesactivado && (esDeOrden || movimiento.esReversa) && (
          <p className="rounded-md bg-tinta-100 px-3 py-2 text-2xs leading-snug text-tinta-600">
            {esDeOrden
              ? `Este movimiento pertenece a la orden ${movimiento.ordenFolio}. Deshacerlo por
                 separado dejaría la orden diciendo una cosa y el inventario otra: la vía correcta
                 es cancelar la orden.`
              : 'Una reversa no se revierte: desactivaría la corrección, no el error.'}
          </p>
        )}

        {!esSistema && !yaDesactivado && (
          <p className="rounded-md bg-tinta-100 px-3 py-2 text-2xs text-tinta-600">
            Solo el operador SISTEMA puede desactivar movimientos.
          </p>
        )}

        {confirmando && (
          <div className="rounded-md border border-rose-200 bg-rose-50 p-3">
            <p className="flex items-center gap-1.5 text-sm font-medium text-rose-800">
              <AlertTriangle className="h-4 w-4" /> Confirmar desactivación
            </p>
            <p className="mt-1 text-2xs leading-snug text-rose-700">
              Se registrará un movimiento de reversa por{' '}
              <strong>{movimiento.deltaFisica > 0 ? '−' : '+'}{Math.abs(movimiento.deltaFisica)}</strong>{' '}
              unidades. El movimiento original no se borra ni se modifica. Si las unidades ya se
              consumieron, la operación se rechazará.
            </p>
            <input
              className="campo mt-2" autoFocus maxLength={500}
              placeholder="Motivo de la desactivación (obligatorio)"
              value={motivo} onChange={(e) => setMotivo(e.target.value)}
            />
            <div className="mt-2 flex justify-end gap-2">
              <button className="boton-secundario" onClick={() => setConfirmando(false)}>
                Cancelar
              </button>
              <button
                className="boton bg-rose-600 text-white hover:bg-rose-700"
                disabled={!motivo.trim() || desactivar.isPending}
                onClick={() => desactivar.mutate()}
              >
                {desactivar.isPending ? 'Desactivando…' : 'Sí, desactivar'}
              </button>
            </div>
          </div>
        )}
      </div>
    </Modal>
  )
}
