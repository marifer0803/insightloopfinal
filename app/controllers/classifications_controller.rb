class ClassificationsController < ApplicationController

  def index
    @classifications = Classification.all
    @pareto = pareto_classifications_with_financial_data
    pareto_tags = @pareto.map { |p| p[:tag] }
    @trend_series = conversation_trends_for(pareto_tags)

    days = 7
      current_start  = (days - 1).days.ago.to_date
      current_end    = Date.current
      previous_start = (2 * days - 1).days.ago.to_date
      previous_end   = days.days.ago.to_date

      current_counts = Conversation
        .joins(:classification)
        .where(classifications: { tag: pareto_tags })
        .where(occurred_on: current_start..current_end)
        .group(“classifications.tag”)
        .count

      previous_counts = Conversation
        .joins(:classification)
        .where(classifications: { tag: pareto_tags })
        .where(occurred_on: previous_start..previous_end)
        .group(“classifications.tag”)
        .count

      @growth_by_tag = pareto_tags.index_with do |tag|
        curr = current_counts[tag].to_i
        prev = previous_counts[tag].to_i

        if prev.zero?
          0
        else
          (((curr - prev) / prev.to_f) * 100).round
        end
      end

      @pareto.each do |item|
        item[:growth] = @growth_by_tag[item[:tag]].to_i
      end

    # Get counts by tag, excluding blank tags (optional)
    counts_hash = Conversation
                    .joins(:classification)
                    .where.not(classifications: { tag: [nil, “”] })
                    .group(“classifications.tag”)
                    .order(Arel.sql(“COUNT(*) DESC”))
                    .count

    # labels (tags) and counts array (already sorted descending by DB)
    @chart_labels = counts_hash.keys
    @chart_counts = counts_hash.values.map(&:to_i)

    # compute cumulative percentage on Ruby side
    total = @chart_counts.sum.nonzero? || 1
    cumulative = []
    running = 0.0
    @chart_counts.each do |c|
      running += c
      cumulative << ((running / total) * 100).round(0)
    end
    @chart_cumulative = cumulative
  end

   def show
    @classification = Classification.find(params[:id])

    trend_hash = conversation_trends_for([@classification.tag])
    trend      = trend_hash[@classification.tag] || { labels: [], values: [] }

    @labels = trend[:labels]
    raw_values = trend[:values]
    @values = smooth_values(raw_values)


  bucket_definitions = {
    "Dia 1"  => (0..3),   # índices 0,1,2,3
    "Dia 5"  => (4..8),
    "Dia 10" => (9..13),
    "Dia 15" => (14..18),
    "Dia 20" => (19..23),
    "Dia 25" => (24..28),
    "Dia 30" => (29..29)
  }

  @volume_points = bucket_definitions.map do |label, range|
    {
      label: label,
      count: raw_values[range].compact.sum
    }
  end

  first_bucket = @volume_points.first[:count]
  last_bucket  = @volume_points.last[:count]

  @volume_change_pct =
    if first_bucket.positive?
      (((last_bucket - first_bucket) * 100.0) / first_bucket).round
    else
      nil
    end

   @conversations = @classification.conversations
                                 .order(created_at: :desc)
                                 .limit(3)


  if @classification.improvements.empty?
    llm = RubyLLM.chat

    response = llm
      .with_instructions(Improvement::IMPROVEMENT_PROMPT)
      .ask(@classification.full_text_of_conversations)

    @improvement = Improvement.create!(
      user: current_user,
      classification: @classification,
      content: response.content
    )
  else
    @improvement = @classification.improvements.last
  end
  @ia_root_cause = generate_root_cause(@conversations)

end

  private

def pareto_classifications_with_financial_data
  # Base volume data per classification tag
  volume_rows = Conversation
    .joins(:classification)
    .select(
      "classifications.tag AS tag,
      COUNT(*) AS conv_count,
      ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER ()) AS pct,
      ROUND(100.0 * SUM(COUNT(*)) OVER (
        ORDER BY COUNT(*) DESC, classifications.tag ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) / SUM(COUNT(*)) OVER ()) AS cum_pct,
      ROUND(100.0 * SUM(COUNT(*)) OVER (
        ORDER BY COUNT(*) DESC, classifications.tag ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) / SUM(COUNT(*)) OVER (), 2) AS cum_pct_2"
    )
    .group("classifications.tag")
    .order("conv_count DESC, classifications.tag ASC")

  tags = volume_rows.map(&:tag)
  return [] if tags.blank?

  # Distinct customers per tag
  total_customers_by_tag = Conversation
    .joins(:classification)
    .where(classifications: { tag: tags })
    .where.not(customer_id: nil)
    .group("classifications.tag")
    .distinct
    .count(:customer_id)

  # Churned customers per tag
  churned_by_tag = Conversation
    .joins(:classification, :customer)
    .where(classifications: { tag: tags }, customers: { status: "churned" })
    .group("classifications.tag")
    .distinct
    .count(:customer_id)

  # Revenue lost (MRR of churned customers) per tag
  revenue_lost_by_tag = Customer
    .joins(conversations: :classification)
    .where(customers: { status: "churned" }, classifications: { tag: tags })
    .group("classifications.tag")
    .distinct
    .sum("customers.mrr")

  # Revenue at risk (MRR of at_risk customers) per tag
  revenue_at_risk_by_tag = Customer
    .joins(conversations: :classification)
    .where(customers: { status: "at_risk" }, classifications: { tag: tags })
    .group("classifications.tag")
    .distinct
    .sum("customers.mrr")

  # Average sentiment per tag
  avg_sentiment_by_tag = Conversation
    .joins(:classification)
    .where(classifications: { tag: tags })
    .where.not(sentiment_score: nil)
    .group("classifications.tag")
    .average(:sentiment_score)

  # Build enriched data
  enriched = volume_rows.map do |row|
    tag = row.tag
    total_cust = total_customers_by_tag[tag].to_i
    churn_count = churned_by_tag[tag].to_i
    churn_rate = total_cust.positive? ? ((churn_count.to_f / total_cust) * 100).round(1) : 0.0
    rev_lost = revenue_lost_by_tag[tag].to_f.round(2)
    rev_at_risk = revenue_at_risk_by_tag[tag].to_f.round(2)
    avg_sent = avg_sentiment_by_tag[tag].to_f.round(2)

    {
      tag: tag,
      count: row.conv_count.to_i,
      pct: row.pct.to_i,
      cum_pct: row.cum_pct.to_i,
      cum_pct_2: row.cum_pct_2.to_f,
      churn_count: churn_count,
      churn_rate: churn_rate,
      revenue_at_risk: rev_at_risk,
      revenue_lost: rev_lost,
      avg_sentiment: avg_sent
    }
  end

  # Filter to 80% Pareto
  pareto_items = enriched.select { |r| r[:cum_pct_2] <= 80.00 }

  # Compute composite priority score
  max_rev_lost = pareto_items.map { |r| r[:revenue_lost] }.max.to_f
  max_avg_sent = pareto_items.map { |r| r[:avg_sentiment] }.max.to_f

  pareto_items.each do |item|
    norm_rev_lost = max_rev_lost.positive? ? (item[:revenue_lost] / max_rev_lost) : 0.0
    norm_avg_sent = max_avg_sent.positive? ? (item[:avg_sentiment] / max_avg_sent) : 0.0
    item[:priority_score] = (
      (item[:churn_rate] / 100.0 * 0.4) +
      (norm_rev_lost * 0.3) +
      (norm_avg_sent * 0.3)
    ).round(3)
  end

  # Sort by priority_score descending
  pareto_items.sort_by { |r| -r[:priority_score] }
end
  def generate_root_cause(conversations)
  texto = conversations.map { |c| c.content }.join("\n")
  prompt = <<~PROMPT
   Você é um analista sênior especializado em diagnóstico de causa raiz.
  Analise as conversas abaixo e gere um diagnóstico extremamente curto, direto e técnico.

  O resultado deve ter:
  • no máximo 2 frases
  • foco total na causa raiz
  • linguagem objetiva, sem floreios
  • mencionar de forma clara o mecanismo do erro (ex: falha de processo, atraso logístico, erro de sistema, política inadequada, comunicação incorreta etc.)

  NÃO retorne lista, bullet points ou textos longos.
  NÃO explique o que está fazendo.

  Exemplo do estilo desejado:
  "Usuários com Android 14 estão enfrentando freeze no pagamento via PIX devido a incompatibilidade entre o WebView atualizado e a biblioteca de pagamentos atual."

  Agora gere UM diagnóstico nesse mesmo estilo:

  Conversas analisadas:
  #{texto}
  PROMPT

  llm = RubyLLM.chat
  resposta = llm.ask(prompt)

  resposta.content
end

  def smooth_values(values)
    return values if values.blank?

    smoothed = values.dup

    (1...smoothed.size).each do |i|
      prev = smoothed[i - 1]
      curr = smoothed[i]

      if curr == 0 && prev > 0
        smoothed[i] = (prev * 0.7).round
      end
    end

    smoothed
  end

  def conversation_trends_for(tags, days: 30)
    return {} if tags.blank?

    start_date = (days - 1).days.ago.to_date
    end_date   = Date.current

    raw_counts = Conversation
      .joins(:classification)
      .where(classifications: { tag: tags })
      .where(occurred_on: start_date..end_date)
      .group("classifications.tag", "conversations.occurred_on")
      .order("classifications.tag", "conversations.occurred_on")
      .count

    trends = Hash.new { |h, k| h[k] = Hash.new(0) }

    raw_counts.each do |(tag, date), count|
      trends[tag][date] = count
    end

    trends.transform_values do |per_day_hash|
    all_dates = (start_date..end_date).to_a

    {
      labels: all_dates.each_with_index.map { |_, idx| "Dia #{idx + 1}" },
      values: all_dates.map { |d| per_day_hash[d] || 0 }
    }
    end
  end
end
