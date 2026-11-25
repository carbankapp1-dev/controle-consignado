# Controle Consignado — como colocar no ar

São 5 etapas. Faça uma de cada vez. Tempo total: uns 30 minutos.

---

## Etapa 1 — Criar o banco (Supabase)

1. Entre em https://supabase.com e clique em **New project**.
   - Nome: `controle-consignado`
   - Senha do banco: crie uma e guarde (não é usada no dia a dia).
   - Região: **South America (São Paulo)**.
2. Espere o projeto ficar pronto (1 a 2 minutos).
3. No menu da esquerda: **SQL Editor** > **New query**.
4. Abra o arquivo `supabase/schema.sql`, copie **tudo**, cole lá e clique em **Run**.
5. Vá em **Project Settings** > **API** e copie:
   - **Project URL**
   - **anon public** (ou "publishable key")
6. Abra o arquivo `js/config.js` e cole essas duas informações nos lugares indicados.

---

## Etapa 2 — Seu usuário de administrador

1. No Supabase: **Authentication** > **Users** > **Add user** > **Create new user**.
   - E-mail: o seu (é o seu "usuário" de administrador).
   - Senha: a sua.
   - Marque **Auto Confirm User**.
2. **SQL Editor** > **New query**, cole a linha abaixo trocando pelo **mesmo e-mail** e clique em **Run**:

   ```sql
   insert into cc_admins (email) values ('seu.email@exemplo.com') on conflict do nothing;
   ```

3. **Importante (segurança):** **Authentication** > **Sign In / Providers** > desligue
   **Allow new users to sign up** e salve.
   Assim ninguém cria conta por fora. As senhas das lojas só são criadas pelo código que você gera.

---

## Etapa 3 — Publicar no GitHub Pages

1. No GitHub, crie um repositório novo (ex.: `controle-consignado`). Pode ser **Public**.
2. Clique em **uploading an existing file** e arraste **todo o conteúdo desta pasta `site`**:
   `index.html`, a pasta `js` e a pasta `supabase`.
3. Clique em **Commit changes**.
4. Vá em **Settings** > **Pages**:
   - Source: **Deploy from a branch**
   - Branch: **main**, pasta **/ (root)** > **Save**.
5. Depois de 1 ou 2 minutos aparece o endereço, algo como:
   `https://SEU-USUARIO.github.io/controle-consignado/`

Abra o endereço e entre com o seu e-mail e senha de administrador.

---

## Etapa 4 — Trazer os dados da versão antiga

**No Google Script antigo**

1. Abra o projeto antigo no editor do Google Script.
2. Ao lado de **Arquivos**, clique em **+** > **Script** e dê o nome `Migracao`.
3. Apague o que vier escrito, cole todo o conteúdo do arquivo `migracao/exportarParaMigracao.gs` e salve.
4. No topo, escolha a função **exportarParaMigracao** e clique em **Executar** (com a sua conta de administrador).
5. No **Registro de execução** aparece um link. Abra e clique em **Baixar**: é o arquivo `Controle Consignado - migracao.json`.

**No site novo**

6. Aba **Importar planilha** > **Trazer dados da versão antiga** > escolha o arquivo `.json`.
7. Confira em **Lojas e acessos**: as lojas e os veículos (com coleta, boleto, envio e rastreio) estarão lá.

> Pode repetir a migração sem duplicar nada. Faça no dia da troca e avise as lojas para usarem só o site novo a partir dali.

---

## Etapa 5 — Liberar o acesso das lojas

1. Aba **Lojas e acessos** > na loja, clique em **Gerar código**.
2. Clique no botão de **copiar** ao lado do código: copia uma mensagem pronta (link, CNPJ e código). Cole no WhatsApp ou e-mail da loja.
3. A loja abre o link > **Primeiro acesso / esqueci a senha** > digita o CNPJ, o código e cria a senha.
4. Nos próximos acessos ela entra com **CNPJ + senha**.

- O código vale **7 dias** e serve uma vez só.
- Depois de **5 tentativas erradas**, o código é bloqueado. Gere outro.
- **Loja esqueceu a senha:** gere um código novo e repita o passo 2.
- Qualquer pessoa logada pode trocar a própria senha no botão **Trocar senha**, no topo.

---

## Para ver sem banco (demonstração)

Coloque `?demo=1` no final do endereço (visão do administrador) ou `?demo=loja` (visão da loja).

## O que mudou em relação à versão do Google Script

- Login com **usuário (CNPJ) e senha**, não mais com a conta Google.
- Cores novas.
- Não envia nem lê e-mails. O pedido de boleto agora é pelo formulário (link).
- **Boleto chegou** é marcado à mão pela loja, depois do aviso para conferir o beneficiário.
- Novo: botão **Desfazer pedido**, para boleto pedido por engano.
- Sai a aba "E-mails de envio".
