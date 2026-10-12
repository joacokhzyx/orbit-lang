# fuzz_crashes

Directorio local ignorado por git (ver `.gitignore`: `fuzz_crashes/`).

Es el destino de `scripts/fuzz_frontend.py`: ante cualquier entrada
mutada cuyo `orbit build` termine con un codigo distinto de 0 (aceptado),
1 (diagnostico limpio) o 2 (rechazo de uso), el fuzzer copia el `.orb`
ofensor aqui como `crash_rc<rc>_case<i>.orb` y sale con codigo 1.

Estar vacio es lo normal: significa que la ultima pasada del fuzzer
no encontro ningun crash nativo. No commitear su contenido; si aparece
un fichero, abrir un defecto con el `.orb` y la semilla usada.
