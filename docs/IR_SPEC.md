# IRv1 — Especificación del IR de Orbit (carril M0, lado lenguaje)

- **Pin del lenguaje:** `5c01cea68f125f06dd3ac82a61776827bdb0c6f3`
- **Estado:** propuesta del lado lenguaje para R6. No es una publicación normativa
  del repo Orbit: en este pin no existe `--emit-ir`, ni spec IR versionada, ni
  corpus IR serializado.
- **Relación con el borrador externo:** `C:/Users/Usuario/Downloads/orbit-r6/docs/IR_SPEC_DRAFT.md`
  se ha usado como propuesta y se ha verificado afirmación por afirmación contra
  `compiler/ir.orb`, `compiler/builder.orb`, `compiler/c_backend.orb`,
  `compiler/route_runtime.orb`, `compiler/cteval.orb` y `runtime/orbit_api.h`.
  Donde este documento y el borrador discrepen, prevalece este documento; donde
  el lenguaje publique otra cosa, prevalece el lenguaje.
- **Regla de huecos:** todo lo marcado `UNSPECIFIED` debe fallar en el loader con
  un diagnóstico que identifique opcode/campo. Prohibido aproximar, prohibido
  crear shims, prohibido inventar semántica.

## 1. Inventario de opcodes (60)

Definidos en `compiler/ir.orb:3-70`, en este orden (índice 0–59):

| # | Opcode | # | Opcode | # | Opcode | # | Opcode |
|---|--------|---|--------|---|--------|---|--------|
| 0 | `nop` | 15 | `ge` | 30 | `db_all` | 45 | `list_pop` |
| 1 | `load_const` | 16 | `and_op` | 31 | `db_where` | 46 | `map_create` |
| 2 | `load_var` | 17 | `or_op` | 32 | `http_response` | 47 | `map_set` |
| 3 | `store_var` | 18 | `not_op` | 33 | `label` | 48 | `map_get` |
| 4 | `decl_var` | 19 | `neg` | 34 | `copy` | 49 | `map_has` |
| 5 | `add` | 20 | `begin_block` | 35 | `arg` | 50 | `map_delete` |
| 6 | `sub` | 21 | `end_block` | 36 | `load_field` | 51 | `map_keys` |
| 7 | `mul` | 22 | `call` | 37 | `store_field` | 52 | `result_ok` |
| 8 | `div` | 23 | `ret` | 38 | `switch_op` | 53 | `result_err` |
| 9 | `mod` | 24 | `jump` | 39 | `type_info` | 54 | `result_unwrap` |
| 10 | `eq` | 25 | `jump_if_false` | 40 | `list_create` | 55 | `result_is_ok` |
| 11 | `ne` | 26 | `alloc` | 41 | `list_push` | 56 | `result_unwrap_err` |
| 12 | `lt` | 27 | `free` | 42 | `list_get` | 57 | `union_create` |
| 13 | `le` | 28 | `db_get` | 43 | `list_set` | 58 | `union_get_tag` |
| 14 | `gt` | 29 | `db_set` | 44 | `list_len` | 59 | `union_get_data` |

El backend C despacha los 60 en `compiler/c_backend.orb:2422-3599`. Su brazo por
defecto (`c_backend.orb:3596-3599`) emite el comentario `/* Unknown opcode */` y
sigue adelante: un loader IRv1 debe convertir ese caso en error fatal, nunca en
comentario.

### 1.1 Productores observados en el builder

"Productor" significa un sitio `ir_init_instr(IROpcode.X)` en
`compiler/builder.orb`. Verificado por búsqueda exhaustiva:

- **Con productor en el builder:** `arg`, `call`, `decl_var`, `load_var`,
  `store_var`, `load_const`, `jump`, `jump_if_false`, `label`, `copy`, `ret`,
  `list_len`, `lt`, `list_get`, `add`, `sub`, `result_ok`, `result_err`, `eq`,
  `union_get_tag`, `union_get_data`, `load_field`, `store_field`, `list_push`,
  `list_set`, `list_pop`, `map_has`, `map_delete`, `map_keys`, `list_create`,
  `not_op`, `neg`, `mul`, `div`, `mod`, `ne`, `le`, `gt`, `ge`, `and_op`,
  `or_op`, `result_is_ok`, `result_unwrap`, `result_unwrap_err`.
  (Sitios representativos: `builder.orb:1218-1231` arg/call, `2606-2681`
  saltos/labels/copy, `2906-2910` y `3910-3975` colecciones, `3117-3192`
  resultados, `3285-3378` uniones/campos, `4584-4597` tabla de binops,
  `4610`/`4618` not/neg, `4831-4854` result_is_ok/unwrap/unwrap_err.)
- **Sin productor en el builder (solo existen en el enum + lowering):**
  `nop`, `begin_block`, `end_block`, `alloc`, `free`, `db_get`, `db_set`,
  `db_all`, `db_where`, `http_response`, `switch_op`, `type_info`,
  `map_create`, `map_set`, `map_get`, `union_create`.
  - `nop` lo produce el plegado de constantes (`compiler/cteval.orb:953,998`).
  - El acceso a DB del lenguaje NO usa `db_*`: baja por `call` a helpers
    `orbit_db_query_*` / `orbit_db_insert` / `orbit_db_update` / `orbit_db_delete`
    (`builder.orb:295-306`, `3585-3634`, `3838-3869`). Los opcodes `db_*` no
    tienen ningún productor en `compiler/*.orb` en este pin.
  - Los métodos de mapa `.has` / `.delete` / `.keys` sí emiten opcodes
    (`builder.orb:4053,4063,4072`); el resto del tráfico de mapas baja por
    `call` (el backend reconoce `orbit_map_create` en la ruta de llamadas,
    `c_backend.orb:773`).
  - Las respuestas HTTP de rutas bajan por `call`, no por `http_response`.

Consecuencia para el loader: los 16 opcodes sin productor son sintácticamente
válidos en IRv1 pero el corpus (§5) no los ejercita; su semántica de ejecución
queda `UNSPECIFIED` salvo lo que el lowering observado fija (§1.2).

### 1.2 Semántica observable por opcode (lowering C observado)

`O1..O3` = operandos etiquetados, `D` = destino. Todo lo no fijado aquí es
`UNSPECIFIED` (§6). Referencias al dispatch en `c_backend.orb:2422-3599`.

| Opcode | Efecto observado en el lowering | Campo/condición que lo decide |
|---|---|---|
| `nop` | Sin efecto | — |
| `load_const` | `D ← O1` (`2427-2430`) | `generateValue` (§2.2) |
| `load_var` | `D ←` variable nombrada en O1 (`2431-2484`); cast según tipo de registro y de variable; nombres con `TAG_` son tags de enum | `registerTypes[D]`, `variableDefType`, Spellings `float`/`int`/`bool`/`result` |
| `store_var` / `decl_var` | `nombre(O1) = cast(valor(O2))` (`2485-2494`); idéntica emisión | `storeCastFor` |
| `add` | Concat `orbit_string_concat(arena,·,·)` si algún operando es string; suma `orbit_float` si algún operando es float; si no, suma entera sobre `(uintptr_t)` (`2495-2508`) | `isStringOperand`, `operandDefType` |
| `sub` / `mul` | Resta/multiplicación float o entera (`2509-2524`) | `operandDefType` |
| `div` / `mod` | División/resto float, o división/resto **con signo** sobre `orbit_int` (`2525-2545`, comentario F-0014) | `operandDefType` |
| `eq` / `ne` | `strcmp()==0` / `!=0` si ambos son string; comparación float; si no, igualdad sobre `(uintptr_t)` (`2546-2573`) | `isStringOperand`, `operandDefType` |
| `lt` / `le` / `gt` / `ge` | Comparación float, o comparación **con signo** sobre `(intptr_t)` (`2582-2612`) | `operandDefType` |
| `and_op` / `or_op` / `not_op` | `&&`, `\|\|`, `!` en C (`2614-2625`) | — |
| `neg` | Negación (`2626-2633`) | tipo float o entero |
| `begin_block` / `end_block` | Abren/cierran `{` / `}` (`2634-2641`) | — |
| `label` | `label_N:;` solo si el label está referenciado (`2642-2647`) | `refLabels` |
| `jump` | `goto label_N` con O1 (`2648-2651`) | — |
| `jump_if_false` | `if (!(O1)) goto label_O2` (`2652-2655`) | — |
| `copy` | `D ← O1` (`2656-2660`) | — |
| `arg` | Sin D: añade O1 a los args pendientes del `call`. Con D: O1 Int es índice de parámetro, `D ←` nombre del parámetro (`2661-2679`) | `dest == -1`, `params` |
| `call` | §3 (protocolo completo: aridad en O2, alias, `print`, indirectas) (`2680-3190`) | O1 (nombre o registro), O2 aridad |
| `ret` | Retorno según `returnType`: `None` → default por tipo (`0`, `0.0`, `return;`, `NULL`); registro/valor → cast por tipo (`3192-3273`); `main` → `int`, ruta → `OrbitResponse*` | `returnType`, nombre |
| `alloc` | `D ← orbit_arena_alloc(arena, O1)`; sin O1, `sizeof(void*)` (`3274-3286`) | O1 tamaño |
| `free` | Solo el comentario `/* free - arena managed */`; no libera (`3287-3290`) | — |
| `load_field` | Lectura de campo; `.length`/`.len` sobre string → `orbit_string_len` (`3291-3351`) | O1 base, O2 nombre (con posible prefijo `dueño.` vía `fieldRefOwner`) |
| `store_field` | Escritura de campo (`3352-3380`) | O1 base, O2 nombre, O3 valor |
| `list_create` | `{ OrbitResult _lr = orbit_list_create_typed(arena, sizeof(void*), O2, elemKind); D = ok ? lista : NULL; }` (`3381-3387`) | O2 capacidad, `elemKind` |
| `list_push` | push tipado según `elemKind` (`3388-3401`) | O1 lista, O2 valor, `elemKind` |
| `list_get` | `D ←` lectura tipada según `elemKind` (`3402-3405`) | O1 lista, O2 índice, `elemKind` |
| `list_set` | Escritura tipada; O2 índice, O3 valor (`3406-3409`) | O1 lista, `elemKind` |
| `list_len` | String → `orbit_string_len`; si no, `(orbit_int)orbit_list_len` (`3410-3417`) | O1 |
| `list_pop` | Error si vacía + lectura del último + acortado (`3418-3427`) | O1 lista, `elemKind` |
| `map_create` | `D = orbit_map_create(O1)` (`3428-3431`) | O1 |
| `map_set` | `D = orbit_map_set(O1, O2, O3)` (`3432-3435`) | O1 mapa, O2 clave, O3 valor |
| `map_get` | `D = orbit_map_get(O1, O2)` (`3436-3439`) | O1 mapa, O2 clave |
| `map_has` | `D = orbit_map_has(O1, O2)` (`3440-3443`) | O1 mapa, O2 clave |
| `map_delete` | `D = orbit_map_delete(O1, O2)` (`3444-3447`) | O1 mapa, O2 clave |
| `map_keys` | `D = orbit_map_keys(O1)` (`3448-3451`) | O1 mapa |
| `result_ok` | Float → `orbit_result_ok_float`; resto → `orbit_result_ok((void*)(uintptr_t)(O1))` (`3452-3463`) | tipo de O1 |
| `result_err` | O2 `None` → `orbit_result_err(código(O1))`; si no → `orbit_result_err(código(O2), mensaje(O1))` (`3464-3477`) | O1 mensaje, O2 código |
| `result_unwrap` | Destino float → `orbit_result_get_float(O1)`; si no → `O1.value` (`3478-3498`) | `registerTypes[D]` |
| `result_unwrap_err` | `O1.error_msg ? O1.error_msg : ""` (`3499-3502`) | O1 |
| `result_is_ok` | `D = O1.ok` (`3503-3506`) | O1 |
| `union_create` | Reserva `orbit_alloc(arena, 16)`, guarda tag (int) + data (puntero) (`3507-3510`) | O1 tag, O2 data |
| `union_get_tag` / `union_get_data` | Lectura de `.tag` / `.data` del layout `{int tag; void* data;}` (`3511-3518`) | O1 unión |
| `switch_op` | `switch (O1) {` o comentario si O1 vacío (`3519-3528`) | O1 |
| `type_info` | Solo el comentario `/* type_info */` (`3529-3532`) | — |
| `db_get` | `D = orbit_db_get(O1[, O2])` (`3533-3547`) | O1, O2 |
| `db_set` | `D = orbit_db_set(O1[, O2[, O3]])` (`3548-3566`) | O1, O2, O3 |
| `db_all` | `D = orbit_db_all(O1)` (`3567-3576`) | O1 |
| `db_where` | `D = orbit_db_where(O1[, O2])` (`3577-3591`) | O1, O2 |
| `http_response` | `ORBIT_API_RESPONSE(O1, O2, O3)` (`3592-3595`) | O1, O2, O3 |

Notas de auditoría:

- `free` observado como no-op y `type_info` como comentario NO son semántica:
  quedan `UNSPECIFIED` (U-09, U-12).
- El layout de unión `{int tag; void* data;}` es texto emitido localmente, no un
  helper contractual del runtime: queda `UNSPECIFIED` (U-14).
- `ORBIT_API_RESPONSE` no está declarado en `runtime/orbit_api.h` (búsqueda sin
  resultados): su punto de definición queda `UNSPECIFIED` (U-15).
- Los símbolos `orbit_db_*` no existen en la variante net (§4, deriva DB).

## 2. Modelo de valores y estructuras

### 2.1 `IRValue` (unión etiquetada, `ir.orb:80-89`)

| Variante | Carga | Constructores (`ir.orb:108-140`) |
|---|---|---|
| `Int` | `int` con signo | `ir_int` |
| `Float` | `float` (== `double` en C, §4) | sin constructor dedicado observado |
| `String` | `string` (literal) | `ir_string` |
| `Sym` | `string` (nombre/símbolo) | `ir_symbol` |
| `Bool` | `bool` | `ir_bool` |
| `Register` | `int` (número de registro) | `ir_register` |
| `Label` | `int` (número de label) | `ir_label` |
| `None` | — | `ir_none` |

Renderizado C observado (`generateValue`, `c_backend.orb:2363-2381`): `Int` →
decimal; `Float` → `orbit_float_to_string_selfhost`; `String` → entrecomillado
con `escapeString`; `Sym` → crudo; `Bool` → `true`/`false`; `Register(n)` →
`r_N` (`n<0` → `"0"`); `Label(n)` → decimal; resto → cadena vacía.

### 2.2 `IRInstruction` (`ir.orb:91-105`)

- `opcode`: uno de los 60 (§1).
- `dest`: `int`; `-1` significa sin destino. Fábrica por defecto `-1`
  (`ir_init_instr`, `ir.orb:142-144`).
- `operand1/2/3`: `IRValue`. Los no usados son `None`.
- `elemKind`: `int` con el código de tipo de elemento de lista
  (`builder.orb:1356-1363`): `0` indeterminado, `1` string, `2` int, `3` float,
  `4` bool, `5` ref. Solo los opcodes de colección lo fijan; solo el builder lo
  decide (`ir.orb:97-104`). `0` baja al accesor no tipado y a destino `void*`.
  El predicado exacto de `5` (`isReferenceKindName`) no se audita aquí:
  `UNSPECIFIED` qué spellings dan 5 (U-01).
- Tipo de registro del destino: `registerTypeForElemKind` (`builder.orb:1380-1386`):
  `1→"string"`, `2→"int"`, `3→"float"`, `4→"bool"`, resto → `"unknown"`.

### 2.3 `IRFunction` (`ir.orb:146-161`)

Campos en orden: `name`, `params` (nombres), `paramTypes` (mismo largo),
`instructions`, `registerCount`, `registerTypes` (largo == `registerCount`),
`returnType`, `isExtern`, `routeMethod`, `routePath`, `routeHasLimit`,
`routeLimitRate`, `routeLimitWindowMs`, `routeLimitBurst`.

- `ir_alloc_register` (`ir.orb:171-176`): el número es el contador actual; añade
  el typeName a `registerTypes`. Vocabulario de tipos observado (abierto, no
  restringido): `"int"`, `"bool"`, `"string"`, `"float"`, `"unknown"`, `"void"`,
  `"void*"`, `"result"`/`"Result"`/`"OrbitResult"`, `"response"`, `"map"`,
  `"list"`, `"object"`, `"string_list"`/`"int_list"`/`"float_list"`/`"bool_list"`/`"ref_list"`,
  spellings `list<…>` / `map<…>`, spellings `fn(params)->ret`, alias `orbit_*`,
  tipos de modelo y de enum. El loader debe aceptar cualquier string.
- `registerTypes` es informativo y se reescribe durante la emisión
  (`inferRegisterTypes`, `c_backend.orb:575-1095`): el loader no debe asumir que
  el C final (o el nativo) se deriva solo de ellos.
- `isExtern == true` → el backend no emite prototipo ni definición
  (`c_backend.orb:193,248`): el símbolo se resuelve fuera. Resolución
  `UNSPECIFIED` (U-16).
- `routeMethod == ""` ⇔ función normal. `initRouteFunction` fija retorno
  `"OrbitResponse*"` (`ir.orb:167-169`). Límites de ruta Kynx opcionales
  (`c_backend.orb:78-90,1837`).
- Los parámetros viven además en un registro plano de kinds por nombre
  (`listKinds`) restaurado por ámbito (`listKindMarks`); dos funciones con un
  parámetro del mismo nombre comparten entrada (`builder.orb:44-74,110-123,
  AGENTS.md`). No reproducible en IR serializado: `UNSPECIFIED` (U-02).

### 2.4 `IRModule`, modelos, tipos, globales, migraciones

- `IRModule` (`ir.orb:220-226`): `functions`, `globals`, `models`, `types`,
  `migrations` (todos listas).
- `IRGlobal` (`ir.orb:228-232`): `name`, `value` (`IRValue`), `typeName`.
  Constructores observados: valor `ir_string` (`builder.orb:2336,2372`) o
  `ir_register` (`builder.orb:2377`). Top-level `var`/`const` es error E1007;
  `val NOMBRE = <lit int|bool>` es `#define` global emitido por
  `generateRoutePreamble`, no por `route_runtime` (AGENTS.md).
- `IRModelDecl` (`ir.orb:187-198`): `name`, `fields` (`IRModelField{name,
  typeName}`), `typeParams`. Una declaración con `typeParams` no vacíos NUNCA
  llega al módulo: vive en `builder.genericModels`; solo las instancias
  sintetizadas (`Box_int`, campos ya sustituidos) entran en `module.models`
  con `typeParams == []` (`builder.orb:647,682,2026-2034`).
- `IRTypeDecl` (`ir.orb:212-218`): `name`, `kind`, `variants` (strings),
  `richVariants` (strings), `methods` (strings). Observado
  (`builder.orb:2044-2072`): `"enum"→"enumeration"`, `"union"→"union_type"`,
  resto de `kind` pasa tal cual (`"alias"`, `"trait"` sin renombrar);
  `variants` = textos de literales; `richVariants` = spellings de payloads;
  **`methods` siempre `[]`** (literal en `builder.orb:2070`).
- `IRVariantDecl`/`IRVariantField` (`ir.orb:200-210`): declarados pero sin
  ningún sitio constructor en `builder.orb` (solo mención de tipos en
  `builder.orb:1312`). Poblamiento `UNSPECIFIED` (U-03).
- `migrations`: lista de strings SQL (`builder.orb:2037-2039`, emisión en
  `c_backend.orb:1816-1825`). Con migraciones o DB, el preámbulo inicializa
  `orbit_db_init(".orbit/data/app.db")` y cierra con `orbit_db_close()`
  (`route_runtime.orb:484,666`).

## 3. Convención de llamadas

### 3.1 Protocolo `arg` / `call`

1. Cada `arg` sin `dest` añade `generateValue(O1)` a la pila pendiente
   (`callArgs`) del backend (`c_backend.orb:2676`).
2. `call` lee O1: `String`/`Sym` → llamada nombrada; cualquier otro valor →
   llamada indirecta.
3. O2 (`Int`) es la aridad registrada por el builder: el `call` consume
   exactamente los últimos `numArgs` pendientes (`2828-2829`). Aridad cero
   significa cero (sin fallback a "todo lo pendiente", `2824-2828`).
4. Alias aplicados por el backend (`2759-2767`): `slice→orbit_string_slice`,
   `at→orbit_string_at`, `find`/`indexOf`/`orbit_string_find→orbit_string_indexOf`.
5. Mínimos de aridad impuestos por el backend (`2811-2823`): `orbit_string_at`,
   `orbit_string_indexOf`, `strcmp` → 2; `orbit_string_slice` → 3;
   `orbit_string_concat` → 2.
6. `print` con exactamente 1 pendiente: string → `print("%s",…)`; registro
   float → `printf` con `orbit_float_to_string`; resto → `printf("%lld\n",
   (long long)(…))` (`2772-2794`). Con ≠1 args emite `/* print */` y descarta
   pendientes (`2795-2800`). Comportamiento observado, no contrato de formato
   (U-17).
7. Sin `dest` necesario cuando el callee retorna void o es `orbit_list_set`
   (`2768-2771`).
8. Nombres que son keywords C reciben sufijo `_` en el call site
   (`isCKeyword`, `2884-2891`); la definición usa `sanitizeIdentifier` con la
   misma regla.
9. Algunas llamadas reciben `arena` como primer argumento (`functionNeedsArena`,
   `2893`): la lista exacta no se audita aquí → `UNSPECIFIED` (U-04).
10. Llamada indirecta (`2693-2757`): O1 es el valor función (registro); la
    firma `fn(params)->ret` sale del tipo del registro; los casts por argumento
    son `orbit_int`/`orbit_string`/`orbit_float`/crudo/`void*` según el tipo de
    parámetro; retorno `"void"` suprime el destino. Orden de evaluación de
    argumentos `UNSPECIFIED` (U-05).

### 3.2 Funciones, registros, retorno

- Toda función no-extern se declara (prototipo) y define. No-`main`/no-ruta →
  `static`. `main` (o su alias) → `orbit_main`, retorno `int`. Ruta →
  retorno `OrbitResponse*` con firma `(OrbitArena* arena, OrbitRequest* req)`
  (`c_backend.orb:193-236`).
- Tipos C vía `mapTypeToC` (`c_backend.orb:359-…`): `int→orbit_int`,
  `float→orbit_float`, `string→orbit_string`, `bool→orbit_bool`,
  `void→void`, `list*→OrbitList*`, `map*→OrbitMap*`, `object→OrbitObject*`,
  `result→OrbitResult`, `response→OrbitResponse*`, enums → su nombre,
  `list<…>`/`map<…>` por base, `*` final preservado. Resto: caída a puntero
  (regla exacta de la cola de la función no auditada → U-06).
- Registros físicos `r_N`. El tipo de declaración sale de `registerTypes[N]`.
  `ret` emite según `returnType` (§1.2, `3192-3273`).
- `orbit_print` se declara `void orbit_print(const char* str)`
  (`runtime/orbit_api.h:611`).

## 4. Runtime y deriva DB (contractual)

- `runtime/orbit_api.h` es el header de compilación separada contra
  `.orbit/lib/libruntime_net.a` (**variante net, sin DB**; `orbit_api.h:3-13,106`):
  ```c
  typedef const char* orbit_string;   /* h:113 */
  typedef int         orbit_int;      /* h:114 — 32 bits en ambos targets x86-64 */
  typedef double      orbit_float;    /* h:115 */
  ```
  `OrbitResult` (`h:177-184`), `OrbitList` (`h:212-224`), `OrbitMap`
  (`h:231-239`), `OrbitRequest`/`OrbitResponse` (`h:280-290`), helpers
  `orbit_list_*_typed/push_*/read_*` (`h:361-531`), `orbit_map_*` (`h:378-382,
  534-554`), `orbit_result_ok/float/err` (`h:321-325`), `orbit_alloc`
  (`h:334`), `orbit_response_*` (`h:697-703`).
- **Deriva DB:** el backend emite `orbit_db_get/set/all/where`
  (`c_backend.orb:3533-3591`) y el preámbulo `orbit_db_init/close`, pero la lib
  net no declara ni enlaza ningún símbolo `orbit_db_*` (cero resultados en
  `orbit_api.h`). Hasta que exista un artefacto de runtime DB publicado y
  pineado, los opcodes `db_get/db_set/db_all/db_where` están excluidos del
  diferencial M1. Sin shims, sin omisión silenciosa: el loader los rechaza.

## 5. Formato textual IRv1

### 5.1 Decisión de formato

IRv1 textual es un **documento JSON UTF-8** (RFC 8259): un solo objeto raíz,
sin BOM, con LF final. JSON es el formato; no hay representación as
...[truncated 11257 chars]