class MessagesController < ApplicationController

  SYSTEM_PROMPT = <<~PROMPT
   Você é um Analista Sênior de Produto e Customer Support integrado a um sistema de análise de atendimentos.

    Seu papel é ajudar o usuário a entender:
    - o que está acontecendo no atendimento ao cliente,
    - quais são os principais problemas,
    - onde está a maior concentração de impacto,
    - e onde focar esforços.

    REGRAS OBRIGATÓRIAS:
    - Baseie TODAS as respostas exclusivamente nos dados fornecidos no contexto.
    - NÃO invente números, causas ou conclusões.
    - NÃO faça suposições além do que os dados permitem.
    - Se não houver dados suficientes para responder, diga claramente que a informação não está disponível.
    - Use apenas as partes do contexto que forem relevantes para a pergunta do usuário.
    - Ignore dados que não tenham relação com a pergunta.

    FORMATO E TOM:
    - Responda sempre em português.
    - Seja objetivo, direto e profissional.
    - Priorize análises, padrões e priorização.
    - Evite explicações longas ou genéricas.
    - Use Markdown quando fizer sentido.

    COMPORTAMENTO ESPERADO:
    - Se a pergunta for sobre resumo, período ou visão geral, apresente uma síntese clara dos principais pontos.
    - Se a pergunta envolver prioridade, foco ou impacto, utilize a análise Pareto (80/20) quando disponível.
    - Se a pergunta for sobre causa raiz, responda de forma curta e técnica.
    - Se a pergunta for sobre ações ou melhorias, organize a resposta em curto, médio e longo prazo.

    PROMPT

  def create
    @chat = current_user.chats.find(params[:chat_id])

    @message = Message.new(message_params)
    @message.chat = @chat
    @message.role = "user"

    if @message.save
    ruby_llm_chat = RubyLLM.chat
    response = ruby_llm_chat.with_instructions(instructions).ask(@message.content)
    Message.create(role: "assistant", content: response.content, chat: @chat)

    redirect_to chat_path(@chat)

    else
      render "chats/show", status: :unprocessable_entity
    end
  end

  def message_params
    params.require(:message).permit(:content)
  end

  private

  def message_params
    params.require(:message).permit(:content)
  end

   def categories_count
    Conversation
      .joins(:category)
      .group("categories.name")
      .count
   end

   def classifications_count
    Conversation
    .joins(:classification)
    .group("classifications.tag")
    .count
   end

# Testing pareto_classifications
def pareto
  rows = Conversation
    .joins(:classification)
    .select(
      "classifications.tag AS tag,
      COUNT(*) AS count,
      ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER ()
      ) AS pct,
      ROUND(
        100.0 * SUM(COUNT(*)) OVER (
          ORDER BY COUNT(*) DESC, classifications.tag ASC
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )
        / SUM(COUNT(*)) OVER ()
      ) AS cum_pct,
      ROUND(
        100.0 * SUM(COUNT(*)) OVER (
          ORDER BY COUNT(*) DESC, classifications.tag ASC
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )
        / SUM(COUNT(*)) OVER (),
      2
      ) AS cum_pct_2"
    )
    .group("classifications.tag")
    .order("count DESC, classifications.tag ASC")

  # Keep only classifications contributing to the first 80%
  rows.select { |r| r.cum_pct_2.to_f <= 80.00 }
end

# Testing pareto_classifications

   def generate_root_cause(conversations)
    texto = conversations.map { |c| c.content }.join("\n")
    prompt = <<~PROMPT
     Você é um analista sênior especializado em diagnóstico de causa raiz.
    Analise as conversas abaixo e gere um diagnóstico extremamente curto, direto e técnico.

    O resultado deve ter:
    • no máximo 2 frases
    • foco total na causa raiz
    • linguagem objetiva, sem floreios
    • mencionar de forma clara o mecanismo do erro (ex: falha de processo, atraso logístico, erro de sistema, política  inadequada, comunicação incorreta etc.)

    NÃO retorne lista, bullet points ou textos longos.
    NÃO explique o que está fazendo.

    Exemplo do estilo desejado:
    "Usuários com Android 14 estão enfrentando freeze no pagamento via PIX devido a incompatibilidade entre o WebView   atualizado e a biblioteca de pagamentos atual."

    Agora gere UM diagnóstico nesse mesmo estilo:

    Conversas analisadas:
    #{texto}
    PROMPT

    llm = RubyLLM.chat
    resposta = llm.ask(prompt)

    resposta.content
  end

  def classification_and_improvements_dados
    Classification
    .joins(:improvements)
    .pluck("classifications.tag", "improvements.content")
    .to_h
    .to_json
  end

  def classification_and_improvements_dados_and_context
    "Segue um JSON com títulos curtos para ações de melhoria de curto prazo, médio prazo e longo prazo pra cada CLASSIFICATION (problema raiz encontrado):
    ```
    #{classification_and_improvements_dados}
    ```
    "
  end

  def pareto_json
    pareto.map do |item|
      {tag: item.tag, percentage: item.pct.to_i}
    end
  end


  def pareto_and_context
    "Segue um JSON com uma lista de CLASSIFICATION chaves e percentuais de ocorrência:
    ```
    #{pareto_json.to_json}
    ```
    "
  end

  def churn_and_sentiment_context
    tags = Classification.pluck(:tag).compact

    return "" if tags.blank?

    # Sentiment avg per classification
    sentiment_by_tag = Conversation
      .joins(:classification)
      .where.not(sentiment_score: nil)
      .group("classifications.tag")
      .average(:sentiment_score)

    # Churn data per classification
    churned_by_tag = Conversation
      .joins(:classification, :customer)
      .where(customers: { status: "churned" })
      .group("classifications.tag")
      .distinct
      .count(:customer_id)

    total_customers_by_tag = Conversation
      .joins(:classification)
      .where.not(customer_id: nil)
      .group("classifications.tag")
      .distinct
      .count(:customer_id)

    revenue_lost_by_tag = Customer
      .joins(conversations: :classification)
      .where(customers: { status: "churned" })
      .group("classifications.tag")
      .distinct
      .sum("customers.mrr")

    revenue_at_risk_by_tag = Customer
      .joins(conversations: :classification)
      .where(customers: { status: "at_risk" })
      .group("classifications.tag")
      .distinct
      .sum("customers.mrr")

    total_revenue_at_risk = Customer.where(status: "at_risk").sum(:mrr).to_f.round(2)
    total_revenue_lost = Customer.where(status: "churned").sum(:mrr).to_f.round(2)

    churn_data = tags.map do |tag|
      total_cust = total_customers_by_tag[tag].to_i
      churn_count = churned_by_tag[tag].to_i
      churn_rate = total_cust.positive? ? ((churn_count.to_f / total_cust) * 100).round(1) : 0.0

      {
        tag: tag,
        avg_sentiment: sentiment_by_tag[tag].to_f.round(2),
        churn_count: churn_count,
        churn_rate: churn_rate,
        revenue_lost: revenue_lost_by_tag[tag].to_f.round(2),
        revenue_at_risk: revenue_at_risk_by_tag[tag].to_f.round(2)
      }
    end.select { |d| d[:churn_count] > 0 || d[:avg_sentiment] > 0 }

    <<~CTX
    DADOS DE CHURN E SENTIMENTO POR CLASSIFICAÇÃO:
    Receita total em risco (at_risk): R$ #{total_revenue_at_risk}
    Receita total perdida (churned): R$ #{total_revenue_lost}

    Detalhamento por classificação:
    ```
    #{churn_data.to_json}
    ```

    Legenda:
    - avg_sentiment: média de 1 (muito positivo) a 5 (crítico)
    - churn_count: quantidade de customers churned
    - churn_rate: percentual de churn entre customers daquela classificação
    - revenue_lost: MRR perdido (customers churned)
    - revenue_at_risk: MRR em risco (customers at_risk)

    Use estes dados para responder perguntas sobre impacto financeiro, churn e sentimento com precisão.
    CTX
  end

  def instructions
    [SYSTEM_PROMPT, classifications_count, categories_count, classification_and_improvements_dados_and_context, pareto_and_context, churn_and_sentiment_context].compact.join("\n\n")
  end
end
