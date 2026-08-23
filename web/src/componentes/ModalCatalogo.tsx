import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ErrorApi, acunarIdOperacion, peticion } from '../lib/api'
import type { Categoria } from '../lib/tipos'
import { Modal, usarAvisos } from './Base'

/** El ALTA en catálogos está reservada a este operador. El motor lo impone. */
export const USUARIO_SISTEMA = 1

export type RegistroCatalogo = Record<string, unknown>

interface Campo {
  clave: string
  etiqueta: string
  obligatorio?: boolean
  ayuda?: string
  tipo?: 'texto' | 'numero' | 'correo' | 'seleccion'
  opciones?: { valor: string; texto: string }[]
  /** Se captura al dar de alta pero después no se corrige. */
  soloAlta?: boolean
  /** El motor solo se lo permite al operador SISTEMA. */
  soloSistema?: boolean
}

/**
 * Los campos por catálogo. La lista es la misma que aceptan el alta y la
 * edición en el backend, y es explícita a propósito: el SKU, los
 * consecutivos, la versión de concurrencia y los sellos de baja los calcula
 * el motor y no se capturan.
 */
const CAMPOS: Record<string, Campo[]> = {
  categorias: [
    { clave: 'codigo', etiqueta: 'Código', obligatorio: true,
      ayuda: 'Exactamente 4 letras mayúsculas. Es el prefijo del SKU: en cuanto la categoría acuña un producto, el motor lo congela.' },
    { clave: 'nombre', etiqueta: 'Nombre', obligatorio: true },
    { clave: 'descripcion', etiqueta: 'Descripción' },
  ],
  almacenes: [
    { clave: 'codigo', etiqueta: 'Código', obligatorio: true,
      ayuda: 'Forma ALM-XXX, longitud fija. No forma parte del SKU: es un localizador.' },
    { clave: 'nombre', etiqueta: 'Nombre', obligatorio: true },
    { clave: 'direccion', etiqueta: 'Dirección' },
  ],
  clientes: [
    { clave: 'nombre', etiqueta: 'Nombre', obligatorio: true },
    { clave: 'correo', etiqueta: 'Correo', tipo: 'correo' },
    { clave: 'telefono', etiqueta: 'Teléfono' },
  ],
  usuarios: [
    { clave: 'nombre', etiqueta: 'Nombre', obligatorio: true },
    { clave: 'correo', etiqueta: 'Correo', tipo: 'correo' },
    { clave: 'rol', etiqueta: 'Rol', tipo: 'seleccion', soloSistema: true,
      ayuda: 'El rol decide quién puede exportar. Cambiarlo está reservado al operador SISTEMA.',
      opciones: [{ valor: 'OPERADOR', texto: 'Operador' },
                 { valor: 'SUPERVISOR', texto: 'Supervisor' }] },
  ],
  productos: [
    { clave: 'categoria_id', etiqueta: 'Categoría', obligatorio: true, tipo: 'seleccion',
      ayuda: 'Recategorizar no reescribe el SKU: quedó acuñado con el prefijo de origen.' },
    { clave: 'nombre', etiqueta: 'Nombre', obligatorio: true },
    { clave: 'descripcion', etiqueta: 'Descripción' },
    { clave: 'precio_unitario', etiqueta: 'Precio unitario', tipo: 'numero' },
  ],
}

const texto = (v: unknown) => (v === null || v === undefined ? '' : String(v))

export function ModalCatalogo({
  recurso, etiqueta, usuarioId, registro, alCerrar,
}: {
  recurso: string; etiqueta: string; usuarioId: number
  /** Presente = corregir ese registro. Ausente = dar de alta uno nuevo. */
  registro?: RegistroCatalogo
  alCerrar: () => void
}) {
  const avisar = usarAvisos()
  const clienteQuery = useQueryClient()
  const editando = registro !== undefined

  const campos = (CAMPOS[recurso] ?? []).filter((c) => !(editando && c.soloAlta))

  const [valores, setValores] = useState<Record<string, string>>(() =>
    editando
      ? Object.fromEntries(campos.map((c) => [c.clave, texto(registro![c.clave])]))
      : {})

  // El id se acuña al abrir: reenviar la misma captura es un reintento, no un
  // duplicado. Vale igual para el alta y para la corrección.
  const [idOperacion] = useState(() => acunarIdOperacion(editando ? 'editcat' : 'altacat'))

  const { data: categorias } = useQuery({
    queryKey: ['catalogo', 'categorias'],
    queryFn: () => peticion<{ elementos: Categoria[] }>('/api/catalogos/categorias'),
    enabled: recurso === 'productos',
  })

  const guardar = useMutation({
    mutationFn: () => editando
      ? peticion(`/api/catalogos/${recurso}/${registro!.id}`, {
          metodo: 'PUT',
          cuerpo: { campos: soloCambiados(), versionEsperada: Number(registro!.version_concurrencia) },
          idOperacion, usuarioId, alcance: `catalogo:editar:${recurso}`,
        })
      : peticion(`/api/catalogos/${recurso}`, {
          metodo: 'POST', cuerpo: valores,
          idOperacion, usuarioId, alcance: `catalogo:alta:${recurso}`,
        }),
    onSuccess: () => {
      avisar({ tono: 'exito',
        texto: editando ? `Registro corregido en ${etiqueta.toLowerCase()}`
                        : `Registro creado en ${etiqueta.toLowerCase()}` })
      clienteQuery.invalidateQueries({ queryKey: ['catalogo'] })
      alCerrar()
    },
    onError: (e: ErrorApi) => avisar({ tono: 'error', texto: e.titulo, detalle: detallar(e) }),
  })

  /**
   * Solo viajan los campos que cambiaron. Mandar los demás haría que corregir
   * el teléfono de un cliente contara como reescribir su nombre, y que el rol
   * viajara en cada edición aunque nadie lo tocara —cosa que el motor
   * rechazaría con WM021 a cualquiera que no sea el operador SISTEMA.
   */
  const soloCambiados = () => Object.fromEntries(
    campos.map((c) => [c.clave, valores[c.clave] ?? ''])
          .filter(([clave, valor]) => valor !== texto(registro![clave as string])))

  const hayCambios = !editando || Object.keys(soloCambiados()).length > 0
  const listo = campos.filter((c) => c.obligatorio)
    .every((c) => (valores[c.clave] ?? '').trim().length > 0)

  return (
    <Modal
      abierto alCerrar={alCerrar}
      titulo={editando ? `Corregir · ${etiqueta}` : `Nuevo registro · ${etiqueta}`}
      descripcion={editando
        ? 'Solo se envían los campos que cambien. Las columnas derivadas las calcula el motor.'
        : 'Las columnas derivadas —SKU, consecutivos, sellos de baja— las calcula el motor.'}
      pie={
        <>
          <button className="boton-secundario" onClick={alCerrar}>Cancelar</button>
          <button className="boton-primario" disabled={!listo || !hayCambios || guardar.isPending}
                  onClick={() => guardar.mutate()}>
            {guardar.isPending ? 'Guardando…' : editando ? 'Guardar' : 'Crear'}
          </button>
        </>
      }
    >
      {editando && (
        <p className="mb-3 rounded border border-tinta-200 bg-tinta-50 px-2.5 py-1.5 text-2xs text-tinta-600">
          Versión <strong className="tabular-nums">{texto(registro!.version_concurrencia)}</strong>.
          Si otro operador la modifica antes de guardar, el cambio se rechaza en vez de pisarlo.
        </p>
      )}

      <div className="space-y-3">
        {campos.map((c) => {
          const bloqueado = c.soloSistema === true && usuarioId !== USUARIO_SISTEMA
          return (
            <div key={c.clave}>
              <label className="etiqueta mb-1 block" htmlFor={c.clave}>
                {c.etiqueta}{c.obligatorio && <span className="ml-0.5 text-rose-500">*</span>}
              </label>

              {c.tipo === 'seleccion' ? (
                <select id={c.clave} className="campo" disabled={bloqueado}
                        value={valores[c.clave] ?? ''}
                        onChange={(e) => setValores((v) => ({ ...v, [c.clave]: e.target.value }))}>
                  <option value="">Seleccione…</option>
                  {(c.opciones ?? (categorias?.elementos ?? []).map((cat) => ({
                    valor: String(cat.id), texto: `${cat.codigo} · ${cat.nombre}`,
                  }))).map((o) => <option key={o.valor} value={o.valor}>{o.texto}</option>)}
                </select>
              ) : (
                <input
                  id={c.clave} className="campo" disabled={bloqueado}
                  inputMode={c.tipo === 'numero' ? 'decimal' : undefined}
                  value={valores[c.clave] ?? ''}
                  onChange={(e) => setValores((v) => ({
                    ...v,
                    // El código va en mayúsculas siempre: el motor lo exige así.
                    [c.clave]: c.clave === 'codigo' ? e.target.value.toUpperCase() : e.target.value,
                  }))}
                />
              )}

              {c.ayuda && <p className="mt-1 text-2xs leading-snug text-tinta-500">{c.ayuda}</p>}
            </div>
          )
        })}
      </div>
    </Modal>
  )
}

/** Traduce los códigos del motor a algo que el operador pueda accionar. */
function detallar(e: ErrorApi) {
  switch (e.codigoWms) {
    case 'WM020': return 'El alta en catálogos está reservada al operador SISTEMA.'
    case 'WM021': return 'Cambiar el rol de un operador está reservado al operador SISTEMA.'
    case 'WM008': return e.detalle ?? 'Otro operador modificó este registro. Vuelva a cargarlo.'
    case '23503': return 'Ese código ya está acuñado en un SKU y por eso no se puede cambiar.'
    case '23505': return 'Ya existe otro registro con ese código.'
    default:      return e.detalle ?? undefined
  }
}

/**
 * Baja lógica y su reverso. Nunca borra: el motor estampa quién y cuándo, y
 * reactivar NO limpia ese sello —la baja ocurrió y su rastro sobrevive—.
 */
export function ModalVigenciaCatalogo({
  recurso, etiqueta, usuarioId, registro, vigente, alCerrar,
}: {
  recurso: string; etiqueta: string; usuarioId: number
  registro: RegistroCatalogo
  /** Estado ACTUAL del registro; la acción es llevarlo al contrario. */
  vigente: boolean
  alCerrar: () => void
}) {
  const avisar = usarAvisos()
  const clienteQuery = useQueryClient()
  const accion = vigente ? 'desactivar' : 'reactivar'
  const [idOperacion] = useState(() => acunarIdOperacion(`vig${accion.slice(0, 3)}`))

  const aplicar = useMutation({
    mutationFn: () => peticion(`/api/catalogos/${recurso}/${registro.id}/${accion}`, {
      metodo: 'POST', idOperacion, usuarioId, alcance: `catalogo:${accion}:${recurso}`,
    }),
    onSuccess: () => {
      avisar({ tono: 'exito',
        texto: vigente ? 'Registro dado de baja' : 'Registro reactivado',
        detalle: vigente
          ? 'Queda sellado con la fecha y el operador. No se borró nada.'
          : 'El sello de la baja anterior se conserva.' })
      clienteQuery.invalidateQueries({ queryKey: ['catalogo'] })
      alCerrar()
    },
    onError: (e: ErrorApi) => avisar({ tono: 'error', texto: e.titulo, detalle: detallarVigencia(e) }),
  })

  return (
    <Modal
      abierto alCerrar={alCerrar}
      titulo={vigente ? `Dar de baja · ${etiqueta}` : `Reactivar · ${etiqueta}`}
      descripcion="La baja es lógica y auditada: el registro sigue existiendo y su historia también."
      pie={
        <>
          <button className="boton-secundario" onClick={alCerrar}>Cancelar</button>
          <button className={vigente ? 'boton-peligro' : 'boton-primario'}
                  disabled={aplicar.isPending} onClick={() => aplicar.mutate()}>
            {aplicar.isPending ? 'Aplicando…' : vigente ? 'Dar de baja' : 'Reactivar'}
          </button>
        </>
      }
    >
      <p className="text-sm text-tinta-700">
        {vigente ? 'Se dará de baja ' : 'Se reactivará '}
        <strong>{texto(registro.nombre)}</strong>
        {registro.codigo ? <> (<span className="font-mono text-2xs">{texto(registro.codigo)}</span>)</> : null}.
      </p>
      <p className="mt-2 text-2xs leading-snug text-tinta-500">
        {vigente
          ? 'Deja de ofrecerse en los formularios, pero los movimientos y las órdenes que ya lo referencian siguen resolviéndolo. Se puede reactivar después.'
          : 'Vuelve a ofrecerse en los formularios. La fecha y el autor de la baja anterior no se borran.'}
      </p>
    </Modal>
  )
}

function detallarVigencia(e: ErrorApi) {
  switch (e.codigoWms) {
    case 'WM022': return 'El operador SISTEMA es el único que puede dar de alta en catálogos; darlo de baja dejaría el sistema sin nadie que pueda hacerlo.'
    case 'WM023': return 'Otro operador se adelantó. Vuelva a cargar la lista.'
    case 'WM014': return 'Toda baja se atribuye a un operador. Seleccione uno en la barra lateral.'
    default:      return e.detalle ?? undefined
  }
}
