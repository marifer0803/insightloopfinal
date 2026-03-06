# Análise do Projeto InsightLoop — Rails 7.1

---

## 1. Estrutura de Models e Relações

### Diagrama de Relações

```
User
 ├── has_many :conversations  (dependent: :destroy)
 └── has_many :chats          (dependent: :destroy)

Chat
 ├── belongs_to :user
 └── has_many :messages        (dependent: :destroy)

Message
 └── belongs_to :chat

Conversation
 ├── belongs_to :user
 ├── belongs_to :classification  (optional)
 └── belongs_to :category        (optional)

Classification
 ├── has_many :conversations
 └── has_many :improvements

Category
 └── has_many :conversations

Improvement
 ├── belongs_to :user
 └── belongs_to :classification
```

### Detalhes de Cada Model

#### `User` (`app/models/user.rb`)
- **Devise modules:** `database_authenticatable`, `registerable`, `recoverable`, `rememberable`, `validatable`
- **Associações:** `has_many :conversations`, `has_many :chats` (ambos `dependent: :destroy`)
- Campos extras: `name`, `surname`, `plan`

#### `Chat` (`app/models/chat.rb`)
- **Associações:** `belongs_to :user`, `has_many :messages` (`dependent: :destroy`)
- **Constantes:** `DEFAULT_TITLE = "Untitled"`, `TITLE_PROMPT`
- **Método:** `generate_title_from_first_message` — usa RubyLLM para gerar título de 3–6 palavras a partir da primeira mensagem do usuário

#### `Message` (`app/models/message.rb`)
- **Associações:** `belongs_to :chat`
- **Validação customizada:** `user_message_limit` — limita a 10 mensagens de role `"user"` por chat (`MAX_USER_MESSAGES = 10`)

#### `Conversation` (`app/models/conversation.rb`)
- **Associações:** `belongs_to :user`, `belongs_to :classification` (optional), `belongs_to :category` (optional)
- **Callbacks:**
  - `before_validation :set_default_occurred_on` — define `occurred_on` como data atual se não fornecida
  - `after_create :generate_classification_and_category` — classificação automática via IA (ver seção 3)

#### `Classification` (`app/models/classification.rb`)
- **Associações:** `has_many :improvements`, `has_many :conversations`
- **Método:** `full_text_of_conversations` — concatena o `content` de todas as conversas associadas

#### `Category` (`app/models/category.rb`)
- **Associações:** `has_many :conversations`
- **Validações:** `name` — presence + uniqueness

#### `Improvement` (`app/models/improvement.rb`)
- **Associações:** `belongs_to :user`, `belongs_to :classification`
- **Constante:** `IMPROVEMENT_PROMPT` — prompt em português para gerar ações de melhoria (curto/médio/longo prazo)

---

## 2. Schema Completo (`db/schema.rb`)

```ruby
ActiveRecord::Schema[7.1].define(version: 2025_12_16_202853) do
  enable_extension "plpgsql"

  create_table "categories", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "chats", force: :cascade do |t|
    t.string "title"
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_chats_on_user_id"
  end

  create_table "classifications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "tag"
    t.text "tag_description"
  end

  create_table "conversations", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "channel"
    t.text "content"
    t.bigint "classification_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "occurred_on", null: false
    t.bigint "category_id"
    t.index ["category_id"], name: "index_conversations_on_category_id"
    t.index ["classification_id"], name: "index_conversations_on_classification_id"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "improvements", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "content"
    t.bigint "classification_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["classification_id"], name: "index_improvements_on_classification_id"
    t.index ["user_id"], name: "index_improvements_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.string "role"
    t.text "content"
    t.bigint "chat_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_id"], name: "index_messages_on_chat_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.string "surname"
    t.string "plan"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "chats", "users"
  add_foreign_key "conversations", "categories"
  add_foreign_key "conversations", "classifications"
  add_foreign_key "conversations", "users"
  add_foreign_key "improvements", "classifications"
  add_foreign_key "improvements", "users"
  add_foreign_key "messages", "chats"
end
```

**Resumo:** 7 tabelas, PostgreSQL, Rails 7.1, versão `2025_12_16_202853`.

---

## 3. Lógica de Negócio (Services, Jobs, Controllers)

> O projeto **não possui** `app/services/`, `app/workers/`, `app/interactors/` ou `app/use_cases/`. Toda a lógica de negócio está nos **models** e **controllers**.

### 3.1 Pipeline de Classificação Automática por IA

**Localização:** `Conversation#generate_classification_and_category` (callback `after_create`)

Fluxo:
1. Busca todas as tags (`Classification.pluck(:tag)`) e categorias (`Category.pluck(:name, :description)`)
2. Monta system prompt instruindo o LLM a classificar a conversa em **uma tag** e **uma categoria**
3. Chama `RubyLLM.chat` com o conteúdo da conversa
4. Parseia a resposta JSON `{"tag":"...","category":"..."}`
5. Associa a `Classification` e `Category` encontradas (fallback: tag `"Outros"`)

### 3.2 Análise de Pareto (80/20)

**Localização:** `ClassificationsController#index` e `MessagesController` (método privado `pareto`)

- Usa **SQL window functions** (`SUM() OVER ORDER BY ... DESC`) para calcular porcentagem acumulada
- Identifica as classificações que representam ~80% do volume de conversas
- Calcula taxa de crescimento (7 dias atuais vs. 7 dias anteriores)

### 3.3 Geração de Sugestões de Melhoria por IA

**Localização:** `ClassificationsController#show`

- Se não existem `Improvement` para a classification, chama RubyLLM com `Improvement::IMPROVEMENT_PROMPT`
- Envia o texto completo de todas as conversas da classification
- Gera ações estruturadas: **Curto Prazo**, **Médio Prazo**, **Longo Prazo**

### 3.4 Análise de Causa Raiz por IA

**Localização:** `ClassificationsController#generate_root_cause` e `MessagesController#generate_root_cause`

- Prompt dedicado para diagnóstico de causa raiz a partir do texto das conversas
- Resposta técnica e concisa gerada pelo LLM

### 3.5 Chat Analítico com Contexto

**Localização:** `MessagesController#create`

- System prompt em português: papel de "Analista de Produto Sênior"
- Injeta contexto completo: contagem por classification, contagem por category, dados Pareto, melhorias existentes
- Regras: respostas baseadas apenas nos dados fornecidos, formato objetivo e profissional

### 3.6 Dashboard Dinâmico

**Localização:** `PagesController#dashboard`

- KPIs por categoria (perguntas, reclamações, insights de produto)
- Agrupamento dinâmico de gráficos baseado no range de datas:
  - ≤ 7 dias → por dia
  - ≤ 31 dias → por semana
  - ≤ 92 dias → por mês
  - > 92 dias → por semana
- Suporte a presets (últimos 7 dias, último mês, último trimestre) e datas customizadas

### 3.7 Geração de Título de Chat por IA

**Localização:** `Chat#generate_title_from_first_message`

- Gera título descritivo de 3–6 palavras via RubyLLM a partir da primeira mensagem do usuário

### 3.8 Jobs

**Localização:** `app/jobs/application_job.rb`

- Apenas a classe base `ApplicationJob` — nenhum job customizado implementado

---

## 4. Principais Rotas

| Método | Rota | Controller#Action | Observação |
|--------|------|-------------------|------------|
| `GET` | `/` | `pages#dashboard` | **Root** — requer autenticação |
| `GET` | `/home` | `pages#home` | Landing page pública |
| `GET` | `/dashboard` | `pages#dashboard` | Dashboard analítico |
| `GET` | `/up` | `rails/health#show` | Health check |
| — | `/users/*` | Devise | Sign in, sign up, password reset |
| `GET` | `/conversations` | `conversations#index` | Lista agrupada por classification |
| `GET` | `/conversations/:id` | `conversations#show` | Detalhe da conversa |
| `GET` | `/conversations/:id/edit` | `conversations#edit` | Edição (lista classifications) |
| `PATCH` | `/conversations/:id` | `conversations#update` | Atualização |
| `GET` | `/conversations/insight_list` | `conversations#insight_list` | Lista de insights |
| `GET` | `/conversations/:id/insight` | `conversations#insight` | Insight individual |
| `GET` | `/classifications` | `classifications#index` | Análise Pareto |
| `GET` | `/classifications/:id` | `classifications#show` | Detalhe + melhorias + causa raiz |
| `POST` | `/chats` | `chats#create` | Cria novo chat |
| `GET` | `/chats/:id` | `chats#show` | Exibe chat com mensagens |
| `POST` | `/chats/:chat_id/messages` | `messages#create` | Envia mensagem + resposta IA |

---

## 5. APIs Externas e Gems de IA/NLP

### API Externa

| API | Configuração | Uso |
|-----|-------------|-----|
| **OpenAI API** | `ENV["OPENAI_API_KEY"]` via `config/initializers/ruby_llm.rb` | Toda a inteligência artificial do sistema |

### Gem de IA

| Gem | Versão | Função |
|-----|--------|--------|
| **`ruby_llm`** | `~> 1.2.0` | Wrapper Ruby para chamadas ao OpenAI. Usado em: classificação automática de conversas, geração de melhorias, análise de causa raiz, títulos de chat, chat analítico |

### Outras Gems Relevantes

| Gem | Função |
|-----|--------|
| `redcarpet` | Renderização de Markdown para HTML (respostas da IA) |
| `rails_charts` | Gráficos no dashboard |
| `devise` | Autenticação de usuários |
| `bootstrap ~> 5.3` | Framework CSS |
| `simple_form` | Formulários |
| `turbo-rails` / `stimulus-rails` | Hotwire (SPA-like) |
| `dotenv-rails` | Variáveis de ambiente (dev/test) |
| `pg` | Adapter PostgreSQL |

---

## Resumo Arquitetural

O **InsightLoop** é uma plataforma de análise de suporte ao cliente que usa IA (OpenAI via `ruby_llm`) para:

1. **Classificar automaticamente** conversas de suporte em tags e categorias
2. **Aplicar análise de Pareto** para identificar os problemas mais impactantes (80/20)
3. **Gerar sugestões de melhoria** estruturadas (curto/médio/longo prazo)
4. **Diagnosticar causas raiz** dos problemas recorrentes
5. **Oferecer um chat analítico** onde o usuário conversa com um "Analista de Produto" IA que responde com base nos dados reais do sistema

Stack: **Rails 7.1** + **PostgreSQL** + **Hotwire** + **Bootstrap 5** + **OpenAI (via ruby_llm)**
