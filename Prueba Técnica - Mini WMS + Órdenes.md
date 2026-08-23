# Prueba Técnica — Mini WMS + Órdenes

## Objetivo

Construir una aplicación web sencilla para administrar productos, inventario en múltiples almacenes y órdenes de venta.

Está permitido y recomendado utilizar herramientas de inteligencia artificial durante todo el desarrollo.

No se evaluará cuánto código fue escrito manualmente. Se evaluará la calidad del resultado, las decisiones tomadas y la forma en que se utilizaron y supervisaron las herramientas de IA.

---

## Productos

El sistema deberá permitir administrar productos.

Como mínimo considerar:

- SKU
- Nombre
- Descripción
- Categoría
- Precio
- Estatus

El SKU deberá permitir identificar de forma inequívoca un producto.

---

## Almacenes e inventario

La compañía cuenta con múltiples almacenes.

Un mismo producto puede existir en diferentes almacenes y tener distintas existencias en cada uno.

El sistema deberá permitir:

- consultar inventario;
- registrar entradas;
- registrar salidas;
- realizar ajustes;
- consultar movimientos históricos.

El inventario deberá mantenerse consistente aun cuando existan múltiples operaciones sobre un mismo producto.

---

## Importación

El sistema deberá permitir realizar una carga masiva de productos e inventario.

La aplicación deberá proporcionar una plantilla descargable que posteriormente pueda ser utilizada para realizar la importación.

El candidato deberá determinar:

- estructura de la plantilla;
- validaciones;
- tratamiento de registros incorrectos;
- comportamiento ante registros existentes o duplicados.

El usuario deberá recibir información suficiente para conocer el resultado de la importación.

---

## Órdenes

El sistema deberá permitir crear órdenes de venta.

Una orden deberá contener:

- cliente;
- almacén;
- productos;
- cantidades;
- precios;
- total;
- estado.

Las órdenes deberán afectar correctamente el inventario conforme avancen dentro de su ciclo de vida.

Considerar al menos los siguientes escenarios:

- creación;
- confirmación;
- envío;
- cancelación.

El sistema no deberá permitir operaciones que produzcan inconsistencias en el inventario.

---

## Operaciones simultáneas

Considere que varios usuarios o procesos pueden operar sobre el mismo inventario al mismo tiempo.

La solución deberá evitar inconsistencias derivadas de operaciones concurrentes.

La estrategia queda a criterio del candidato.

---

## Solicitudes repetidas

Considere que una operación enviada al API podría ejecutarse nuevamente debido a reintentos, problemas de red u otros escenarios.

El candidato deberá decidir si este escenario requiere tratamiento especial y, en su caso, cómo resolverlo.

---

## Dashboard

La aplicación deberá incluir un pequeño dashboard que permita visualizar información relevante de la operación.

Como mínimo deberá incluir indicadores relacionados con:

- productos;
- inventario;
- almacenes;
- órdenes.

Se deberá incluir al menos una representación gráfica.

La información presentada queda a criterio del candidato.

---

## Interfaz

La aplicación deberá permitir realizar los principales flujos desde una interfaz web.

No se evaluará diseño gráfico avanzado.

Se espera una interfaz funcional y suficientemente clara para operar el sistema.

---

## API y base de datos

La aplicación deberá contar con:

- API REST;
- base de datos relacional;
- frontend web.

La estructura de endpoints, modelo de datos y arquitectura quedan a criterio del candidato.

---

## Docker

La solución deberá poder ejecutarse utilizando Docker.

Idealmente deberá ser posible iniciar el ambiente completo mediante:

```bash
docker compose up
```

---

## Datos iniciales

La aplicación deberá incluir información suficiente para poder probar los principales flujos sin tener que capturar todo desde cero.

---

## Pruebas

La solución deberá incluir pruebas automatizadas para las reglas que el candidato considere más importantes.

Se evaluará especialmente la selección de escenarios que decidió probar.

---

## Ambigüedades

Los requerimientos pueden contener situaciones que no están completamente definidas.

Esto es intencional.

El candidato puede:

- realizar preguntas;
- proponer una solución;
- establecer supuestos;
- documentar decisiones.

Se evaluará la capacidad para identificar situaciones que puedan afectar el comportamiento del sistema.\

---

## Uso de IA

Se permite utilizar cualquier herramienta de inteligencia artificial.

Ejemplos:

- Claude Code;
- Codex;
- Cursor;
- GitHub Copilot;
- Windsurf;
- ChatGPT;
- Claude.

Se deberá entregar evidencia del uso realizado durante la prueba.

Cuando la herramienta lo permita, incluir el transcript o historial de la sesión.

Adicionalmente incluir un archivo:

`AI-USAGE.md`

con una breve descripción de:

- herramientas utilizadas;
- principales tareas delegadas;
- decisiones tomadas;
- problemas encontrados;
- correcciones realizadas;
- forma utilizada para validar el resultado.

---

## Entregables

Entregar un repositorio Git con:

- código fuente;
- pruebas;
- configuración Docker;
- README;
- evidencia de uso de IA.

El README deberá incluir instrucciones suficientes para ejecutar la aplicación.

---

## Resultado esperado

Una vez ejecutada la aplicación deberá ser posible demostrar, como mínimo, un flujo similar a:

```text
Productos
   ↓
Inventario
   ↓
Orden
   ↓
Procesamiento de orden
   ↓
Actualización de inventario
   ↓
Consulta de movimientos
   ↓
Dashboard
```

Además deberá ser posible:

```text
Descargar plantilla
   ↓
Capturar información
   ↓
Importar
   ↓
Consultar resultado
```

---

## Evaluación

Se evaluará principalmente:

- entendimiento del problema;
- identificación de ambigüedades;
- decisiones técnicas;
- calidad del código;
- consistencia del modelo;
- manejo de inventario;
- manejo de errores;
- pruebas;
- arquitectura;
- uso efectivo de IA;
- supervisión del código generado;
- validación del resultado.

No necesariamente se espera completar el 100% de la solución.

Si algo queda pendiente deberá indicarse claramente qué se implementó, qué faltó y cuál sería el siguiente paso.



## Contacto

Las preguntas, propuestas y entregables deberán ser enviadas a gvelazquez@axsistec.com.