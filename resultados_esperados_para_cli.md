Este sería el ejemplo perfecto de como debería correr en la CLI el lenguaje orbit
$ orbit app.orb

  ORBIT v1.0.0  ready in 142 ms

  Core
  - Environment   validated (env.orbit)
  - Security      3 roles active
  - Database      connected (mysql)

  Network
  > Local:        http://localhost:3000
  > Network:      http://192.168.1.45:3000



Este sería lo que sucede en un error
$ orbit app.orb

  ORBIT v1.0.0  failed to start

  [ERROR] env/missing-variable
  The required environment variable 'DB_URL' is not defined.

  file: /project/env.orbit:4
  3 |     port: Int = 3000
  4 |     db_url: String
    |     ^^^^^^ (required)

  Help: Define 'DB_URL' in your shell or .env file.

y esto al usar debug
$ orbit app.orb --debug

  ORBIT v1.0.0  debug mode active

  [runtime] bootstrapping engine...
  [env]     mapping: PORT -> 3000 (default)
  [env]     mapping: API_KEY -> [secret]
  [auth]    registering role: 'admin' (global)
  [auth]    registering role: 'owner' (parameterized)
  [router]  GET  /stats ....................... @admin
  [router]  POST /posts/:id ................... @admin, @owner(id)
  [db]      pool initialized (min: 5, max: 20)

  Listening on http://localhost:3000


Ahora el Build
este sería el ejemplo en una falla
$ orbit build app.orb --release


Build exitoso
$ orbit build app.orb --release

  ORBIT  build successful

  Artifacts
  - main.exe          1.2 MB (native binary)
  - schema.json       4.0 KB (metadata)
  - assets/           240 KB (static)

  Optimizations
  - Tree shaking      Active (removed 14 unused modules)
  - Inlining          Active (32 functions inlined)
  - Env security      Hardened (Secret types encrypted)

  Ready for production in 1.2s
