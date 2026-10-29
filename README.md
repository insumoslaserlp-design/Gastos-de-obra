# Gastos de Obra

App para registrar gastos, jornadas, adelantos y cobros de obra desde el celular, con informes y envío del detalle de pago por WhatsApp.

- `index.html`: la app (funciona sin señal y se instala en el celular).
- `sw.js`, `manifest.json`, `icon.svg`: lo que la hace instalable y usable sin conexión.
- `servidor/`: la base de datos en Supabase (correr `esquema.sql` y después `esquema-2-usuarios.sql`).
- `prototipo.html`: la maqueta de prueba, con datos de ejemplo.

La clave que aparece en `index.html` es la clave pública de Supabase: está bien que esté en el código. Los permisos de cada rol los controla la base de datos.
