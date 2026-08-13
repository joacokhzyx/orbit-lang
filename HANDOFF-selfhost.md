# Handoff: bootstrap self-hosted de Orbit

Objetivo: que el compilador de Orbit se compile a si mismo hasta alcanzar un punto
fijo (stage2.exe.c identico a stage3.exe.c).

Estado real al 2026-08-13 (HEAD `92b9f17`). Leelo entero antes de tocar nada.
Corrida fresca del 2026-08-13 con `zig-out/bin/orbit.exe` (Debug, Zig local
`0.17.0-dev.1503+1f1bee62e`; el pin de CI es `0.17.0-dev.1737+de207594e`).
Los fixes previos (`ae2f3d7` cache de longitud del lexer, `6a3b495` acceso O(1) a
chars, `6bce0c4` fix de `orbit_list_push` en `c_backend.orb`) ya estan dentro del
snapshot descrito en la seccion 2, que reemplaza el estado viejo del 2026-08-07.

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

## 2. Estado actual (corrida fresca 2026-08-13, HEAD `92b9f17`)

**Paso 1 (seed -> stage1):** ok. `stage1.exe` generado por `zig-out/bin/orbit.exe`.

**Paso 2 (stage1 -> stage2):** ok. `stage2.exe.c` (1.8 MB) y `stage2.exe` producidos.
El fallo de la corrida vieja que moria al lanzar `zig cc` NO se reprodujo: la
invocacion del subproceso funciona hoy.

**Paso 3 (stage2 -> stage3):** sigue muriendo, ahora dentro del Pass 3, al construir
la funcion `tokTypeToString`:

```
[pass3] decl 51
[buildFn] tokTypeToString

[ORBIT RUNTIME CRASH] ExceptionCode 0xC0000005 at address 00007FF660FB2ED0
[bootstrap] Failed to build Stage 3 compiler.
error: BootstrapStage3Failed        (src/main.zig:1279 runBootstrapMode)
```

Puntos a diagnosticar:

- Muere en `[buildFn] tokTypeToString`, inmediatamente despues de `[pass3] decl 51`.
  `tokTypeToString` vive en `compiler/token.orb`; es el siguiente candidato a leer.
- El crash es `0xC0000005` sin traza de Zig: el fallo esta en `src/runtime` (C
  compilado aparte) o en una llamada a un subproceso/sistema. Candidatos habituales
  segun seccion 4: `orbit_string_concat`/`strcmp` con NULL, o un NULL que viajo desde
  un `orbit_list_get` fuera de rango.
- Nunca se escribio `stage3.exe.c` (verificar con timestamps antes de diagnosticar).
- No confundir con la corrida vieja: ahi el paso 2 fallaba al lanzar `zig cc` y el
  paso 3 moria a los "306 decls". Ahora el paso 2 pasa y el paso 3 avanza hasta la
  funcion 52 del Pass 3. Es progreso: hay un solo bloqueador localizable.

---

## 3. Primera tarea, en este orden

### 3.1 Descartar que el fallo del paso 2 sea artefacto del script

Entre la ultima corrida buena del paso 2 y la que fallo, lo unico que cambio fue:

1. dos `print` de instrumentacion agregados a `compiler/builder.orb` (ver seccion 5)
2. la redireccion `*> archivo.log` que usa `runall.ps1`

La sospecha principal es (2): el pipeline lanza un subproceso mientras stdout es un
handle de archivo y no una consola. Corre el paso 2 a mano, SIN redireccion:

```
.\compiler\selfhost\stage1.exe build .\compiler\main.orb -o .\compiler\selfhost\stage2.exe
$LASTEXITCODE
```

- Si pasa: el bug del paso 2 es de la captura de salida, no del compilador. Arregla
  `runall.ps1` (por ejemplo con `Tee-Object` o `2>&1 | Tee-Object`) y segui al 3.2.
- Si falla igual: el problema esta en como el pipeline invoca el subproceso. Mira la
  funcion de ejecucion de comandos en `compiler/pipeline.orb`.

### 3.2 Localizar el crash del paso 3

La instrumentacion ya esta puesta y sirve justo para esto. Corre el paso 3 y fijate
cual es el ultimo `[pass3] decl N` y el ultimo `[buildFn] <nombre>` antes de morir.
Eso acota el crash a una funcion concreta del fuente.

Una vez que tengas el nombre, abri esa funcion en el `.orb` correspondiente y busca
que construccion del lenguaje usa. La clave interpretativa esta en la seccion 4.

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

## 5. Instrumentacion temporal que hay que sacar despues

En `compiler/builder.orb` hay dos `print` agregados solo para depurar:

- en `buildAST`, dentro del bucle del Pass 3: `print("[pass3] decl " + ...)`
- al inicio de `buildFunction`: `print("[buildFn] " + f.name)`

Quitalos cuando el bootstrap converja. Mientras tanto son muy utiles.

El compilador ya es ruidoso de por si (`[sema] declareSymbol ...` por cada simbolo).
Esos prints son preexistentes; tambien conviene limpiarlos al final, pero no ahora.

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

1. Los tres pasos corren sin crash.
2. El paso 3 imprime `Program has 306 decls` y `After Pass 3: 210 functions`.
3. `fc.exe stage2.exe.c stage3.exe.c` no reporta diferencias.

Sobre el punto 3, expectativa realista: es poco probable que de identico al primer
intento. `stage2.exe.c` lo genera stage1 y `stage3.exe.c` lo genera stage2, que son
binarios producidos por caminos distintos. Si stage3 compila y funciona pero `fc.exe`
lista diferencias, eso ya es un avance grande, y esas diferencias son exactamente el
mapa de lo que falta para converger. Analizalas una por una en vez de asumir fracaso.

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
