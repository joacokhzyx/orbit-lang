# Cambios Recientes

## 2026-04-06 (Core hardening follow-up)

- Se publica en `main` el hardening del backend C para retornos por defecto en funciones non-void generadas.
- Se valida compilacion end-to-end sin warning de retorno para `test.orb` y `test_phase2.orb`.
- Se actualiza `STATUS.md` con el estado real del core y el foco de ejecucion para Fase 2.
- Se formaliza plan operativo de Sprint 1 para Fase 2 del compilador.

## 2026-04-06

- Limpieza de artefactos históricos de build y logs locales.
- Se agrega `scripts/clean_workspace.ps1` para limpieza reproducible.
- Se agrega `.gitignore` local para evitar reincidir con logs/binarios.
- Se establece `STATUS.md` como fuente única de estado técnico.
- Se retiran documentos de estado contradictorios.
