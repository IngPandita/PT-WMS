import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ArrowRight } from 'lucide-react'
import { ErrorApi, acunarIdOperacion, peticion } from '../lib/api'
import type { FilaTablero } from '../lib/tipos'
import { Modal, usarAvisos } from './Base'

interface Props {
  fila: FilaTablero
  usuarioId: number
  alCerrar: () => void
}

/**
 * Ajuste manual de existencia.
 *
 * Se captura la cantidad OBJETIVO, no un delta: es lo que hace un conteo
 * físico —el operador ve 15 en el anaquel y escribe 15—. La conversión a delta
 * la hace la base bajo el row lock; calcularla aquí sería una carrera con
 * cualquier otro operador que mueva el producto entre tanto.
 *
 * El id_operacion se acuña al ABRIR el modal y se conserva mientras la
 * cantidad no cambie, así que reintentar tras un timeout es seguro. Cambiar la
 * cantidad SÍ es otra intención y acuña un id nuevo.
 */
export function ModalAjuste({ fila, usuarioId, alCerrar }: Props) {
  const [objetivo, setObjetivo] = useState<string>(String(fila.cantidadFisica))
  const [motivo, setMotivo] = useState('Conteo físico')
  const [idOperacion, setIdOperacion] = useState(() => acunarIdOperacion('establecer'))
  const [ultimoValorEnviado, setUltimoValorEnviado] = useState<number | null>(null)
  const avisar = usarAvisos()
  const clienteQuery = useQueryClient()

  const valor = Number(objetivo)
  const esEntero = /^\d+$/.test(objetivo.trim())
  const valido = esEntero && valor >= 0 && valor >= fila.cantidadReservada
  const delta = valor - fila.cantidadFisica

  const aplicar = useMutation({
    mutationFn: () => {
      // Si la cantidad cambió respecto al último envío, es otra intención.
      let id = idOperacion
      if (ultimoValorEnviado !== null && ultimoValorEnviado !== valor) {
        id = acunarIdOperacion('establecer')
        setIdOperacion(id)
      }
      setUltimoValorEnviado(valor)
      return peticion<{ cantidadFisica: number; fueReenvio: boolean }>(
        '/api/inventario/establecer',
        {
          metodo: 'POST',
          cuerpo: {
            productoId: fila.productoId, almacenId: fila.almacenId,
            cantidadObjetivo: valor, motivo,
            // La versión SÍ viaja aquí: escribir una cantidad absoluta sobre
            // una lectura obsoleta descartaría en silencio lo que otro
            // operador acaba de hacer.
            versionEsperada: fila.versionConcurrencia,
          },
          idOperacion: id, usuarioId,
          alcance: `establecer:producto=${fila.productoId}:almacen=${fila.almacenId}`,
        })
    },
    onSuccess: (r) => {
      avisar({
        tono: 'exito',
        texto: `${fila.productoSku} quedó en ${r.cantidadFisica}`,
        detalle: r.fueReenvio
          ? 'Era un reenvío: se devolvió el resultado original.'
          : 'Se registró un movimiento de ajuste auditable.',
      })
      clienteQuery.invalidateQueries({ queryKey: ['inventario'] })
      clienteQuery.invalidateQueries({ queryKey: ['movimientos'] })
      clienteQuery.invalidateQueries({ queryKey: ['indicadores'] })
      alCerrar()
    },
    onError: (e: ErrorApi) => avisar({
      tono: 'error',
      texto: e.titulo,
      detalle: e.codigoWms === 'WM008'
        ? 'Otro operador movió este producto. Cierre y vuelva a abrir para ver la cantidad vigente.'
        : (e.detalle ?? undefined),
    }),
  })

  return (
    <Modal
      abierto alCerrar={alCerrar}
      titulo={`Ajustar existencia · ${fila.productoSku}`}
      descripcion={`${fila.productoNombre} en ${fila.almacenCodigo}`}
      pie={
        <>
          <button className="boton-secundario" onClick={alCerrar}>Cancelar</button>
          <button className="boton-primario" disabled={!valido || delta === 0 || aplicar.isPending}
                  onClick={() => aplicar.mutate()}>
            {aplicar.isPending ? 'Aplicando…' : 'Aplicar ajuste'}
          </button>
        </>
      }
    >
      <div className="space-y-3">
        <div className="flex items-center gap-3 rounded-md bg-tinta-50 px-3 py-2.5">
          <div>
            <p className="etiqueta">Existencia actual</p>
            <p className="text-lg font-semibold tabular-nums">{fila.cantidadFisica}</p>
          </div>
          <ArrowRight className="mt-3 h-4 w-4 text-tinta-400" />
          <div>
            <p className="etiqueta">Quedará en</p>
            <p className="text-lg font-semibold tabular-nums text-acento-700">
              {esEntero ? valor : '—'}
            </p>
          </div>
          <div className="ml-auto text-right">
            <p className="etiqueta">Movimiento</p>
            <p className="text-lg font-semibold tabular-nums">
              {esEntero && delta !== 0 ? (delta > 0 ? `+${delta}` : delta) : '—'}
            </p>
          </div>
        </div>

        <div>
          <label className="etiqueta mb-1 block" htmlFor="objetivo">Existencia contada</label>
          <input
            id="objetivo" className="campo tabular-nums" inputMode="numeric"
            value={objetivo} autoFocus
            // Solo dígitos: no se aceptan decimales ni signos.
            onChange={(e) => setObjetivo(e.target.value.replace(/[^\d]/g, ''))}
          />
          {!esEntero && objetivo !== '' && (
            <p className="mt-1 text-2xs text-rose-600">Debe ser un número entero, sin decimales.</p>
          )}
          {esEntero && valor < fila.cantidadReservada && (
            <p className="mt-1 text-2xs text-rose-600">
              No puede quedar por debajo de {fila.cantidadReservada}: esas unidades ya están
              comprometidas con órdenes confirmadas.
            </p>
          )}
        </div>

        <div>
          <label className="etiqueta mb-1 block" htmlFor="motivo">Motivo</label>
          <input id="motivo" className="campo" value={motivo}
                 onChange={(e) => setMotivo(e.target.value)} maxLength={500} />
        </div>

        <p className="text-2xs leading-snug text-tinta-500">
          El ajuste no reescribe la existencia en silencio: genera un movimiento con su
          usuario, fecha, delta e identificador de operación. Reintentar es seguro.
        </p>
      </div>
    </Modal>
  )
}
