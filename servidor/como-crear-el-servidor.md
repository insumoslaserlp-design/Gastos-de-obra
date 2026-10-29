# Cómo crear el servidor (10 minutos, gratis)

## 1. Crear la cuenta en Supabase
1. Entrá a https://supabase.com y tocá **Start your project**. Podés entrar con tu cuenta de Google o de GitHub.
2. Tocá **New project**.
   - Name: `gastos-de-obra`
   - Database password: inventá una clave y **guardala** (no me la mandes).
   - Region: **South America (São Paulo)**, la más cercana.
3. Esperá 1 o 2 minutos a que termine de crearse.

## 2. Cargar la base de datos
1. En el menú de la izquierda entrá a **SQL Editor**.
2. Abrí el archivo `esquema.sql` (está en esta misma carpeta), copiá todo y pegalo.
3. Tocá **Run**. Tiene que decir "Success".

## 3. Mandarme dos datos
En **Project Settings → API** (o **Connect**) copiá y mandame:
- **Project URL** (algo como `https://abcd1234.supabase.co`)
- **anon public key** (un texto largo que empieza con `eyJ...`)

Esos dos datos son públicos: la app los necesita para conectarse y la seguridad la ponen los permisos por rol que ya están en la base. **No me mandes** la clave de la base ni la "service_role key".

## 4. Conectar GitHub (para guardar el código y publicar la app gratis)
1. Si no tenés cuenta, creala en https://github.com.
2. Creá un repositorio vacío llamado `gastos-de-obra` (botón **New repository**, privado está bien).
3. Conectá GitHub a Claude en https://claude.ai/connect-github y avisame.
