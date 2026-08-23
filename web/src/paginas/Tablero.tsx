import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  Bar, BarChart, CartesianGrid, Legend, Line, LineChart,
  ResponsiveContainer, Tooltip, XAxis, YAxis,
} from 'recharts'
import { Encabezado } from '../App'
import { peticion } from '../lib/api'
import type { Indicadores } from '../lib/tipos'
import { EstadoVacio, Skeleton } from '../componentes/Base'

const MONEDA = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN', maximumFractionDigits: 0 })
const NUMERO = new Intl.NumberFormat('es-MX')

// Un solo acento y grises. Cada serie se distingue por posición, no por saturación.
const COLORES = { fisico: '#4f46e5', reservado: '#a5b4fc', entrada: '#4f46e5', salida: '#f43f5e' }

function Indicador({ etiqueta, valor, apoyo }: { etiqueta: string; valor: string; apoyo?: string }) {
  return (
    <div className="tarjeta px-4 py-3">
      <p className="etiqueta">{etiqueta}</p>
      <p className="mt-1 text-xl font-semibold tabular-nums tracking-tight text-tinta-900">{valor}</p>
      {apoyo && <p className="mt-0.5 text-2xs text-tinta-500">{apoyo}</p>}
    </div>
  )
}

export function PaginaTablero() {
  const [dias, setDias] = useState(30)
  const { data, isLoading } = useQuery({
    queryKey: ['indicadores', dias],
    queryFn: () => peticion<Indicadores>(`/api/indicadores?dias=${dias}&topN=8`),
    refetchInterval: 15_000,
  })

  if (isLoading || !data) {
    return (
      <>
        <Encabezado titulo="Tablero" descripcion="Indicadores de la operación." />
        <div className="grid grid-cols-4 gap-3 p-6">
          {Array.from({ length: 8 }).map((_, i) => <Skeleton key={i} className="h-20" />)}
        </div>
      </>
    )
  }

  const o = data.operacion

  // La serie llega por día y tipo; se pivotea a entradas/salidas por día.
  const porDia = new Map<string, { dia: string; entradas: number; salidas: number }>()
  for (const fila of data.serieDiaria) {
    const dia = String(fila.dia).slice(0, 10)
    const delta = Number(fila.delta_neto_fisico ?? 0)
    const actual = porDia.get(dia) ?? { dia, entradas: 0, salidas: 0 }
    if (delta >= 0) actual.entradas += delta
    else actual.salidas += Math.abs(delta)
    porDia.set(dia, actual)
  }
  const serie = [...porDia.values()].sort((a, b) => a.dia.localeCompare(b.dia)).slice(-30)

  const almacenes = data.porAlmacen.map((a) => ({
    almacen: String(a.almacen_codigo),
    fisico: Number(a.unidades_fisicas ?? 0),
    reservado: Number(a.unidades_reservadas ?? 0),
  }))

  return (
    <>
      <Encabezado titulo="Tablero" descripcion="Indicadores de productos, inventario, almacenes y órdenes." />

      <div className="space-y-4 p-6">
        <section className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <Indicador etiqueta="Productos activos" valor={NUMERO.format(o.productos_activos)} />
          <Indicador etiqueta="Unidades en existencia" valor={NUMERO.format(o.unidades_fisicas)}
                     apoyo={`${NUMERO.format(o.unidades_reservadas)} reservadas`} />
          <Indicador etiqueta="Valor del inventario" valor={MONEDA.format(o.valor_inventario)} />
          <Indicador etiqueta="Por reponer" valor={NUMERO.format(o.productos_existencia_baja)}
                     apoyo="productos bajo su mínimo" />
          <Indicador etiqueta="Órdenes en borrador" valor={NUMERO.format(o.ordenes_borrador)} />
          <Indicador etiqueta="Confirmadas" valor={NUMERO.format(o.ordenes_confirmadas)}
                     apoyo={`${MONEDA.format(o.valor_comprometido)} comprometidos`} />
          <Indicador etiqueta="Enviadas" valor={NUMERO.format(o.ordenes_enviadas)} />
          <Indicador etiqueta="Canceladas" valor={NUMERO.format(o.ordenes_canceladas)} />
        </section>

        <section className="grid gap-4 lg:grid-cols-5">
          <div className="tarjeta p-4 lg:col-span-3">
            <h2 className="text-sm font-medium text-tinta-800">Movimiento diario</h2>
            <p className="mb-3 text-2xs text-tinta-500">Unidades que entraron y salieron cada día.</p>
            <ResponsiveContainer width="100%" height={220}>
              <LineChart data={serie} margin={{ top: 4, right: 8, bottom: 0, left: -12 }}>
                <CartesianGrid stroke="#eceef0" vertical={false} />
                <XAxis dataKey="dia" tick={{ fontSize: 11, fill: '#8f99a4' }}
                       tickFormatter={(d: string) => d.slice(5)} tickLine={false} axisLine={false} />
                <YAxis tick={{ fontSize: 11, fill: '#8f99a4' }} tickLine={false} axisLine={false} />
                <Tooltip contentStyle={{ fontSize: 12, borderRadius: 6, border: '1px solid #d9dde1' }} />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <Line type="monotone" dataKey="entradas" name="Entradas"
                      stroke={COLORES.entrada} strokeWidth={2} dot={false} />
                <Line type="monotone" dataKey="salidas" name="Salidas"
                      stroke={COLORES.salida} strokeWidth={2} dot={false} />
              </LineChart>
            </ResponsiveContainer>
          </div>

          <div className="tarjeta p-4 lg:col-span-2">
            <h2 className="text-sm font-medium text-tinta-800">Existencias por almacén</h2>
            <p className="mb-3 text-2xs text-tinta-500">Unidades físicas y cuántas están comprometidas.</p>
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={almacenes} margin={{ top: 4, right: 8, bottom: 0, left: -12 }}>
                <CartesianGrid stroke="#eceef0" vertical={false} />
                <XAxis dataKey="almacen" tick={{ fontSize: 11, fill: '#8f99a4' }} tickLine={false} axisLine={false} />
                <YAxis tick={{ fontSize: 11, fill: '#8f99a4' }} tickLine={false} axisLine={false} />
                <Tooltip contentStyle={{ fontSize: 12, borderRadius: 6, border: '1px solid #d9dde1' }} />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <Bar dataKey="fisico" name="En existencia" fill={COLORES.fisico} radius={[3, 3, 0, 0]} />
                <Bar dataKey="reservado" name="Reservado" fill={COLORES.reservado} radius={[3, 3, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </section>

        <section className="grid gap-4 lg:grid-cols-2">
          {/* KPI 1 — Demanda. Definida como unidades EMBARCADAS: es el unico
              tipo que produce el surtido de una orden, o sea consumo real de
              un cliente. Se excluyen las SALIDA manuales (merma, correccion) y
              las RESERVA, que estan comprometidas pero aun no salieron; la
              reserva vigente se muestra aparte para no mezclarlas. */}
          <div className="tarjeta overflow-hidden">
            <div className="flex items-start justify-between border-b border-tinta-200 px-4 py-3">
              <div>
                <h2 className="text-sm font-medium text-tinta-800">Productos con mayor demanda</h2>
                <p className="text-2xs text-tinta-500">
                  Unidades embarcadas en los ultimos {data.diasDemanda} dias.
                </p>
              </div>
              <select className="campo w-24 !py-1 !text-2xs" value={dias}
                      onChange={(e) => setDias(Number(e.target.value))}>
                {[7, 30, 60, 90].map((d) => <option key={d} value={d}>{d} dias</option>)}
              </select>
            </div>
            {data.mayorDemanda.length === 0 ? (
              <EstadoVacio titulo="Sin embarques en el periodo"
                           descripcion="Confirme y envie una orden para que aparezca demanda aqui." />
            ) : (
              <table className="w-full text-sm">
                <thead className="bg-tinta-50/60">
                  <tr className="[&>th]:px-4 [&>th]:py-2 [&>th]:text-left [&>th]:font-medium [&>th]:text-tinta-600">
                    <th className="w-10">#</th><th>SKU</th><th>Producto</th>
                    <th className="!text-right">Demandadas</th><th className="!text-right">Comprometidas</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-tinta-100">
                  {data.mayorDemanda.map((d) => (
                    <tr key={String(d.producto_id)}>
                      <td className="px-4 py-2 tabular-nums text-tinta-400">{String(d.posicion)}</td>
                      <td className="px-4 py-2 font-mono text-2xs text-tinta-600">{String(d.producto_sku)}</td>
                      <td className="px-4 py-2 text-tinta-800">
                        {String(d.producto_nombre)}
                        <p className="text-2xs text-tinta-400">{String(d.categoria_nombre)}</p>
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums font-semibold">
                        {String(d.unidades_demandadas)}
                        <p className="text-2xs font-normal text-tinta-400">
                          {String(d.embarques)} embarque(s)
                        </p>
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums text-tinta-500">
                        {String(d.unidades_comprometidas)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>

          {/* KPI 2 — Existencia insuficiente. El umbral es cantidad_minima, que
              el modelo ya tenia. El faltante se mide contra la DISPONIBLE y no
              contra la fisica: lo reservado ya esta comprometido con ordenes
              confirmadas y no puede cubrir demanda nueva. */}
          <div className="tarjeta overflow-hidden">
            <div className="border-b border-tinta-200 px-4 py-3">
              <h2 className="text-sm font-medium text-tinta-800">Existencia insuficiente</h2>
              <p className="text-2xs text-tinta-500">
                Disponible por debajo del minimo. Lo reservado no cuenta: ya esta comprometido.
              </p>
            </div>
            {data.existenciaInsuficiente.length === 0 ? (
              <EstadoVacio titulo="Todo por encima del minimo"
                           descripcion="Ningun producto activo esta por debajo de su existencia minima." />
            ) : (
              <table className="w-full text-sm">
                <thead className="bg-tinta-50/60">
                  <tr className="[&>th]:px-4 [&>th]:py-2 [&>th]:text-left [&>th]:font-medium [&>th]:text-tinta-600">
                    <th>SKU</th><th>Producto</th><th>Alm.</th>
                    <th className="!text-right">Disp.</th><th className="!text-right">Minimo</th>
                    <th className="!text-right">Faltan</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-tinta-100">
                  {data.existenciaInsuficiente.map((f, i) => (
                    <tr key={i}>
                      <td className="px-4 py-2 font-mono text-2xs text-tinta-600">{String(f.producto_sku)}</td>
                      <td className="px-4 py-2 text-tinta-800">
                        {String(f.producto_nombre)}
                        {Number(f.cantidad_reservada) > 0 && (
                          <p className="text-2xs text-tinta-400">
                            {String(f.cantidad_fisica)} en piso, {String(f.cantidad_reservada)} reservadas
                          </p>
                        )}
                      </td>
                      <td className="px-4 py-2 font-mono text-2xs text-tinta-500">{String(f.almacen_codigo)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{String(f.cantidad_disponible)}</td>
                      <td className="px-4 py-2 text-right tabular-nums text-tinta-500">{String(f.cantidad_minima)}</td>
                      <td className="px-4 py-2 text-right tabular-nums font-semibold text-amber-700">
                        {String(f.faltante)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </section>

        <section className="tarjeta overflow-hidden">
          <div className="border-b border-tinta-200 px-4 py-3">
            <h2 className="text-sm font-medium text-tinta-800">Aportación por operador</h2>
            <p className="text-2xs text-tinta-500">
              Cada movimiento conserva su autor: los de un operador dado de baja siguen siendo resolubles.
            </p>
          </div>
          <table className="w-full text-sm">
            <thead className="bg-tinta-50/60">
              <tr className="[&>th]:px-4 [&>th]:py-2 [&>th]:text-left [&>th]:font-medium [&>th]:text-tinta-600">
                <th>Operador</th><th>SKU</th><th className="!text-right">Movimientos</th><th className="!text-right">Delta</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-tinta-100">
              {data.aportacionPorUsuario.slice(0, 8).map((a, i) => (
                <tr key={i}>
                  <td className="px-4 py-2 text-tinta-800">{String(a.usuario_nombre)}</td>
                  <td className="px-4 py-2 font-mono text-2xs text-tinta-600">{String(a.producto_sku)}</td>
                  <td className="px-4 py-2 text-right tabular-nums text-tinta-600">{String(a.movimientos)}</td>
                  <td className="px-4 py-2 text-right tabular-nums font-medium text-tinta-900">
                    {Number(a.delta_fisico_total) > 0 ? '+' : ''}{String(a.delta_fisico_total)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      </div>
    </>
  )
}
