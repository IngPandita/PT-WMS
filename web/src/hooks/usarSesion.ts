import { createContext, useContext } from 'react'
import type { Usuario } from '../lib/tipos'

interface Sesion {
  usuario: Usuario | null
  usuarios: Usuario[]
  cambiarUsuario: (id: number) => void
}

export const ContextoSesion = createContext<Sesion>({
  usuario: null, usuarios: [], cambiarUsuario: () => {},
})

/**
 * El operador activo. No hay autenticación en el alcance de la prueba, pero
 * SÍ atribución: la API rechaza con WM014 cualquier mutación sin operador, y
 * cambiar de operador invalida toda intención en vuelo — su id lleva el
 * operador como prefijo.
 */
export const usarSesion = () => useContext(ContextoSesion)
