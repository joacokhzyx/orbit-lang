# Handoff: bootstrap self-hosted de Orbit

Objetivo: que el compilador de Orbit se compile a si mismo hasta alcanzar un punto
fijo (stage2.exe.c identico a stage3.exe.c).

Estado real al 2026-08-14 (HEAD `2bd0443`). Leelo entero antes de tocar nada.
Corrida fresca del 2026-08-14 con `zig-out/bin/orbit.exe` (Debug, Zig local
`0.17.0-dev.1503+1f1bee62e`; el pin de CI es `0.17.0-dev.1737+de207594e`).
Los fixes previos (`ae2f3d7` cache de longitud del lexer, `6a3b495` acceso O(1) a
chars, `6bce0c4` fix de `orbit_list_push` en `c_backend.orb`) ya estan dentro del
snapshot descrito en la seccion 2. El bootstrap **converge** desde el 2026-08-14:
ver seccion 2.

---

## 1. Como se compila

Secuencia de tres pasos. El primero NO es opcional: `orbit.exe` es el compilador
semilla construido con Zig, y es el unico que puede propagar un cambio del fuente
hacia los stages. Si tocas cualquier `.orb` del compilador y no rehaces el paso 1,
estas probando binarios viejos.

```
.\orbit.exe                       build .\compiler\main.orb -o .\compiler\selfhost\stage1.exe
.\compiler\selfhost\stage1.exe    build .\compiler\main.orb -o .\compiler\selfhost\stage2.exe
.\compiler\selfhost\stage2.exe    build .\compiler\main.orb -o .\compiler\selfhost\stage3.exe
```

Hay un script que hace los tres y resume el resultado: `.\scratch\runall.ps1`.
(`scratch/` es local y esta git-ignored: si no lo tenes, los tres comandos de arriba
son el flujo completo.)

El pipeline genera C y lo compila con:
`<CC> -O0 -Wno-error=int-conversion -Wno-error=incompatible-pointer-types <cPath> -o <out> -I src/runtime [-lws2_32]`
con `CC` por defecto `zig cc`. Cada stage deja su C al lado: `stageN.exe.c`.

---

## 2. Estado actual (corrida fresca 2026-08-14, HEAD `2bd0443`)

**Paso 1 (seed -> stage1):** ok. `stage1.exe` generado por `zig-out/bin/orbit.exe`.

**Paso 2 (stage1 -> stage2):** ok. `stage2.exe.c` (1.8 MB) y `stage2.exe` producidos.

**Paso 3 (stage2 -> stage3):** ok. `stage3.exe.c` y `stage3.exe` producidos.

**Paso 4 (stage3 -> stage4):** ok. `stage4.exe.c` y `stage4.exe` producidos.

**Convergencia: ALCANZADA.** `stage3.exe.c` es byte-identico a `stage4.exe.c`
(verificado por SHA256 en la corrida del 2026-08-14). Es decir, la tercera y la cuarta
generacion, producidas por caminos distintos (stage2 y stage3), generan el mismo C.

### Que habia que arreglar para converger

El ultimo bloqueador era el resolver de imports (`compiler/resolver.orb` +
`resolveModuleAST` en el pipeline). El crash `0xC0000005` que mataba `stage1 -> stage2`
en "Resolving module imports" tenia dos causas:

1. **Truncamiento de punteros en la inferencia de tipos del seed** (`src/codegen/c_backend.zig`).
   Una variable como `val decl = p.decls.get(i)` se tipaba `.int` por default cuando su
   RHS tenia tipo desconocido. Como `orbit_int` es `int` (32 bits), el `load_var` de
   `decl` emitia `(orbit_int)(uintptr_t)(decl)`, truncando el puntero `ASTNode*` de
   64 bits a 32. El `match ASTNode.ImportStmt(imp)` leia el tag de un puntero corrupto.
   Fix: el default de variables de tipo desconocido paso de `.int` a `.usize`
   (uintptr_t), coherente con la regla ya existente "widen to 64-bit so pointer values
   are never truncated through orbit_int".
2. **Concat con operandos int/float/bool** (seed y selfhost). `string_concat_mixed.orb`
   (`"total=" + total + ", ok=" + successFlag + ", ratio=" + ratio`) crasheaba por
   cast/truncamiento de los operandos no-string. Se arreglo en ambos backends
   (`boolean_literal` en el parser, inferencia de `load_var`, casts `(orbit_float)`,
   y el handling del concat en `c_backend.orb`).

Ademas se incorporaron literales de `char` y `boolean` en el selfhost (lexer/parser).

---

## 3. Proximo trabajo (ya no es depurar el crash)

El bootstrap converge desde el 2026-08-14; la seccion 2 describe que habia que arreglar.
Los pasos 3.x de este documento (que describian como cazar el crash de stage3) quedaron
obsoletos: ese crash ya no existe. Si reapareciera un `0xC0000005`, la guia de
interpretacion esta en la seccion 4 y el historial de bugs en la seccion 6.

Trabajo pendiente real del compilador selfhost:

1. **Limpieza de prints de debug.** El compilador es ruidoso (ver seccion 5). Quitar los
   prints por-funcion/por-declaracion (`[genC]`, `[genFn]`, `[genFn-2]`, `[buildFn]`,
   `[sema sig]`, `[sema body]`, `[pass3] decl`, `[buildAST]`) y el resto de debug, pero
   **convertir** los prints de error (`[sema error]`, `Parser error`, `Semantic error`,
   `Import error`, `Invalid token fallback`) en output de error funcional. Tras tocar
   cualquier `.orb`, rehacer stage1 (seed) -> stage2 -> stage3 -> stage4 y reverificar
   convergencia.
2. **Backend nativo** (`src/backend/`): desbloquear `alloc`/`db_*`/`http_*` en
   `capabilities.zig` y añadir `--emit=lir`; luego `load_field`/`store_field`, colecciones
   (`list_*`/`map_*`), `result_*`/`union_*` y float SSE2. Ver `PLAN.md`.

---

## 4. Contexto imprescindible para interpretar cualquier crash

### Por que aparecen bugs nuevos a medida que avanzamos

Hasta el parche de hoy, el destructuring de uniones etiquetadas estaba roto: los
patrones tipo `ASTNode.Program(p)` comparaban el tag del escrutinio contra un puntero
a nodo recien alocado, asi que NUNCA acertaban y todo caia al brazo `_`.

Consecuencia: hay decenas de brazos de `match` en el compilador que jamas se habian
ejecutado en la historia de este bootstrap. Ahora se ejecutan por primera vez. Es
esperable que aparezcan bugs latentes en ese codigo. No los trates como regresiones
del parche sin evidencia; lo mas probable es que sean codigo nunca antes ejercitado.

### Panic vs. crash mudo

Distincion diagnostica de alto valor:

- **`thread NNNN panic: ...` con traza** = el chequeo de UB de Zig atrapo el fallo en
  el C generado por nuestro pipeline. Te da archivo, linea y funcion. Anda directo ahi.
- **`0xC0000005` sin ningun mensaje** = el fallo esta en `src/runtime` (C compilado
  aparte, sin esa instrumentacion) o en una llamada al sistema. Candidatos habituales:
  `orbit_string_concat` o `strcmp` recibiendo NULL.

Ojo con esto: `orbit_list_get` devuelve NULL cuando el indice se sale de rango en vez
de fallar. Un NULL puede viajar muy lejos del punto donde se origino.

### Correspondencia entre tags y direcciones

Cuando un panic dice `misaligned address 0xNN`, ese numero suele ser un tag de
`ASTNode` usado como puntero. Convertilo a decimal y buscalo en esta lista:

```
0 Program, 1 FunctionDecl, 2 RouteDecl, 3 ModelDecl, 4 TypeDecl, 5 FieldDecl,
6 TraitDecl, 7 ImplDecl, 8 VarDecl, 9 ConstDecl, 10 ScheduleDecl, 11 ConfigDecl,
12 ImportStmt, 13 UseStmt, 14 ExpressionStmt, 15 If, 16 While, 17 For, 18 Return,
19 Match, 20 MatchCase, 21 Try, 22 Literal, 23 BinaryOp, 24 UnaryOp, 25 Call,
26 MemberAccess, 27 IndexAccess, 28 ListLiteral, 29 Assignment, 30 TypeAnnotation,
31 GenericParam, 32 Decorator, 33 Block, 34 Break, 35 Continue, 36 Param,
37 FieldInit, 38 Empty
```

Asi se identificaron `0x16` = 22 = `Literal` y `0x26` = 38 = `Empty`.

---

## 5. Instrumentacion / prints de debug

El compilador selfhost es ruidoso de por si. Inventario (al 2026-08-14): ~52 `print`
de debug repartidos en `sema.orb` (Pass 1-4, sig, body), `pipeline.orb` (progreso),
`c_backend.orb` (`[genC]`, `[genFn]`, `[genFn-2]`), `builder.orb` (`[buildAST]`,
`[pass3]`, `[buildFn]`, `[field-owner-miss]`) y `main.orb` (`[bootstrap]`, `[selfhost]`).

- Los prints **por-funcion/por-declaracion** son los mas ruidosos (crecen con el tamano
  del programa): `[genC]`, `[genFn]`, `[genFn-2]`, `[buildFn]`, `[sema sig]`,
  `[sema body]`, `[pass3] decl`.
- Los prints de **progreso** (`[pipeline] ...`, `[buildAST] ...`, `[sema] Pass N ...`)
  se pueden quitar.
- Los prints de **error** (`[sema error]`, `[sema ERROR]`, `Parser error`, `Semantic
  error`, `Import error`, `Invalid token fallback`) NO se borran: son el diagnostico que
  el compilador le muestra al usuario. Deben mantenerse (idealmente sin prefijo debug).
- Los prints **funcionales** (doctor, `lextrace`, CLI usage/errores, relay de
  subprocesos, y el `print` que `c_backend.orb` emite en el C generado) se mantienen.

La limpieza queda registrada como trabajo pendiente en la seccion 3. Tras tocar cualquier
`.orb` hay que rehacer stage1 (seed) -> stage2 -> stage3 -> stage4 y reverificar
convergencia.

---

## 6. Bugs ya resueltos (no los reintroduzcas)

**Bug #1 - `c_backend.orb`, `generateFunction`.** El reseteo de `strRegs`, `strVars`
y `declVars` y el sembrado de parametros string ocurrian DESPUES de
`inferRegisterTypes`. Se movieron antes. Sintoma: concatenacion de strings emitida
donde no correspondia; `checkNode` paso de 1167 a 753 lineas de C.

**Bug #3 - `builder.orb`, brazo `MemberAccess` de `buildExpr`.** Habia un bloque
`if modelFieldIsUnion(...) { ... return tagReg }` que devolvia el tag en lugar del
campo. Se elimino; ahora hace `return fieldReg`. Mato el panic
`misaligned address 0x16`.

**Bug #4 - `c_backend.orb`, `generateInstruction`.** Los opcodes `lt`, `le`, `gt`,
`ge` casteaban a `uintptr_t`, lo que rompia TODOS los centinelas negativos del
compilador: `lookupSymbol`/`lookupFunction` (`parentId = -1` contra `scopeId >= 0`),
`findType` (`-1`), `getEnumNameFromTag` (`indexOf` -> `-1`), `generateValue`
(`if v.value < 0`). Con `uintptr_t`, `-1` es enorme y toda comparacion de orden se
invierte. Se cambio a `intptr_t` en esos cuatro brazos. `eq` y `ne` quedaron intactos
a proposito: no dependen del signo. Mato el panic `null pointer of type 'Scope'`.

**Bug #5 - `builder.orb`, `buildMatchStatement` y `buildMatchExpr`.** El bug grande.
El brazo `ASTNode.Call(callPattern)` (patron de destructuring con payload) hacia
`val varPatReg = buildExpr(builder, callPattern.callee)` para obtener el valor contra
el cual comparar el tag. Pero `buildExpr` construye un NODO, no devuelve el entero del
tag, asi que la comparacion nunca podia ser verdadera. Se reemplazo por una carga
explicita de la constante `tagOwner + "_TAG_" + tagName`. Hay un brazo hermano
`ASTNode.MemberAccess(mp)` para variantes sin payload (`ASTNode.Empty =>`) que usa la
misma tecnica y sirve de modelo.

Este parche es el que hizo que stage2 por fin imprimiera
`[buildAST] Program has 306 decls`.

---

## 7. Trampas conocidas del entorno

**`fc` en PowerShell no es el comparador de archivos.** Es alias de `Format-Custom`.
Para comparar hay que usar `fc.exe`:

```
fc.exe .\compiler\selfhost\stage2.exe.c .\compiler\selfhost\stage3.exe.c
```

**Verifica los timestamps antes de sacar conclusiones.** Ya se perdio tiempo
diagnosticando un `stage2.exe.c` que en realidad era de una corrida anterior porque
el paso que debia regenerarlo habia fallado. `runall.ps1` borra `stage3.exe.c` antes
de correr justamente por esto.

**Despues de cada edicion, releé la region editada.** Una vez se dio por aplicado un
parche porque el diff mostraba las zonas tocadas, pero dentro de cada zona solo habia
entrado parte del cambio. El resultado fue un compilador que generaba un modulo con
cero funciones y varias horas perdidas. No confies en el diff resumido.

**Desambiguar ediciones en codigo duplicado.** `buildMatchStatement` y
`buildMatchExpr` tienen bloques byte-identicos. Truco que funciona: edita primero uno
anclando hacia abajo hasta una linea que solo exista en esa funcion
(`buildNode(builder, c.body)` en la version statement,
`val bodyReg = buildExpr(builder, c.body)` en la version expr). Una vez editado el
primero, el segundo queda unico y se puede editar con un `oldText` de una sola linea.

**No arregles el error `call to undeclared function 'orbit_main'` con un
forward-declare.** Ese error es un SINTOMA: significa que el modulo IR quedo sin
funciones y el C generado salio vacio (30 lineas en vez de 45000). Declarar
`orbit_main` esconderia el problema real.

---

## 8. Mapa de archivos

`compiler/builder.orb` (~1774 lineas, LF) - AST a IR. Aca vivieron los bugs #3 y #5.
Orden: helpers de scope y tipos, `buildAST` (3 pases), `buildDecl`, `buildFunction`,
`buildNode`, `buildMatchStatement`, `buildMatchExpr`, `buildCall`, `buildExpr`.

`compiler/c_backend.orb` (~1844 lineas, LF) - IR a C. Aca vivieron los bugs #1 y #4.
`generateC` emite macros de variantes, enums, typedefs, forward decls y `main`.
Despues `inferRegisterTypes`, `generateFunction`, `generateInstruction`.

`compiler/sema.orb` - analisis semantico, cuatro pasadas. La cuarta son los cuerpos.
`compiler/pipeline.orb` - orquestacion y la invocacion de `zig cc`.
`compiler/ast.orb` - definicion de `ASTNode` y los modelos de nodo.
`compiler/parser.orb` - NO fue leido todavia. Produce `elseBody = ASTNode.Empty`.
Otros: `ir.orb`, `lexer.orb`, `optimizer.orb`, `resolver.orb`, `token.orb`,
`memory.orb`, `extern.orb`, `fmt.orb`, `doctor.orb`, `frontend/frontend.orb`.

---

## 9. Definicion de terminado

1. Los pasos 1-4 corren sin crash (seed -> stage1 -> stage2 -> stage3 -> stage4).
2. El paso 3 imprime `Program has 306 decls` y `After Pass 3: 210 functions`.
3. `stage3.exe.c` es byte-identico a `stage4.exe.c` (verificado por SHA256).

El punto 3 es el gate de convergencia: `stage3.exe.c` lo genera stage2 y `stage4.exe.c`
lo genera stage3, que son binarios producidos por caminos distintos. Si ambos generan el
mismo C, el compilador alcanzo el punto fijo.

---

## 10. Herramientas

El entorno no tiene `grep`. La busqueda por nombre de archivo existe, pero para buscar
DENTRO de archivos grandes (el C generado ronda las 46000 lineas) el patron que se uso
es: script PowerShell en `scratch\` con `Get-Content` + `Select-String`, cortando
rangos de lineas a `scratch\cut\`. Hay once ejemplos, `extract.ps1` a `extract11.ps1`.

Detalle util: para localizar la definicion de una funcion en el C generado y no
engancharte con su forward declaration, exigi la llave de apertura al final:

```powershell
Select-String -Path $c -Pattern '^static .*\bNOMBRE\s*\(.*\)\s*\{\s*$'
```
