# Cambios Recientes

## 2026-04-06

- Limpieza de artefactos históricos de build y logs locales.
- Se agrega `scripts/clean_workspace.ps1` para limpieza reproducible.
- Se agrega `.gitignore` local para evitar reincidir con logs/binarios.
- Se establece `STATUS.md` como fuente única de estado técnico.
- Se retiran documentos de estado contradictorios.

## Resumen de Implementaciones

- **Parser**: Se añadió soporte para expresiones de nivel superior (`expression_stmt`) y manejo de identificadores que pueden ser palabras clave.
- **Lambda**: Se implementó el nodo `arrow_fn` con parámetros, cuerpo y bandera `is_expr`.
- **AST**: Se añadió el nodo `expression_stmt` y se actualizó la definición de `arrow_fn`.
- **Compilación**: `zig build` compila sin errores y el binario `orbit_binary.exe` se genera correctamente.
- **Ejecución**: `orbit_binary.exe dev test.orb` ya se ejecuta sin errores de sintaxis.

## Próximos Pasos

1. Ejecutar pruebas de producción.
2. Validar tipos de parámetros lambda.
3. Optimizar generación de código C.
4. Actualizar documentación de sintaxis.
