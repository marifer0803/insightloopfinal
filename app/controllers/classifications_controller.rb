class ClassificationsController < ApplicationController

  def index
    @classifications = Classification.all
    @pareto = pareto_classifications

    pareto_tags = @pareto.map(&:tag)
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
      .group("classifications.tag")
      .count

    previous_counts = Conversation
      .joins(:classification)
      .where(classifications: { tag: pareto_tags })
      .where(occurred_on: previous_start..previous_end)
      .group("classifications.tag")
      .count

    @growth_by_tag = pareto_tags.index_with do |tag|
      curr = current_counts[tag].to_i
      prev = previous_counts[tag].to_i
      prev.zero? ? 0 : (((curr - prev) / prev.to_f) * 100).round
    end

    @pareto.each do |item|
      growth_value = @growth_by_tag[item.tag].to_i
      item.define_singleton_method(:growth) { growth_value }
    end

    counts_hash = Conversation
                    .joins(:classification)
                    .where.not(classifications: { tag: [nil, ""] })
                    .group("classifications.tag")
                    .order(Arel.sql("COUNT(*) DESC"))
                    .count

    @chart_labels = counts_hash.keys
    @chart_counts = counts_hash.values.map(&:to_i)

    total = @chart_counts.sum.nonzero? || 1
    cumulative = []
    running = 0.0
    @chart_counts.each do |c|
      running += c
      cumulative << ((running / total) * 100).round(0)
    end
    @chart_cumulative = cumulative

    # Real KPIs
    @total_conversations = Conversation.count
    @avg_sentiment = Conversation.where.not(sentiment_score: nil).average(:sentiment_score)&.round(1) || 0
    @revenue_at_risk = Customer.where(status: "at_risk").sum(:mrr)
    @revenue_lost = Customer.where(status: "churned").sum(:mrr)

    # Classification table with real metrics
    @classification_rows = build_classification_table
  end

  def show
    @classification = Classification.find(params[:id])

    trend_hash = conversation_trends_for([@classification.tag])
    trend      = trend_hash[@classification.tag] || { labels: [], values: [] }

    @labels = trend[:labels]
    raw_values = trend[:values]
    @values = smooth_values(raw_values)

    bucket_definitions = {
      "Dia 1"  => (0..3),
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

    # Real volume percentage
    total_convos = Conversation.count
    classification_convos = @classification.conversations.count
    @volume_pct = total_convos.positive? ? ((classification_convos * 100.0) / total_convos).round : 0

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

  def build_classification_table
    all_tags = Classification.joins(:conversations).distinct

    all_tags.map do |classification|
      convos = classification.conversations
      volume = convos.count
      next if volume.zero?

      avg_sentiment = convos.where.not(sentiment_score: nil).average(:sentiment_score)&.round(1) || 0

      customer_ids = convos.where.not(customer_id: nil).pluck(:customer_id).uniq
      if customer_ids.any?
        customers = Customer.where(id: customer_ids)
        total_customers = customers.count
        churned_customers = customers.where(status: "churned").count
        churn_rate = total_customers.positive? ? ((churned_customers * 100.0) / total_customers).round(1) : 0
        revenue_lost = customers.where(status: "churned").sum(:mrr)
      else
        churn_rate = 0
        revenue_lost = 0
      end

      priority_score = (volume * 0.3) + (avg_sentiment * 0.25) + (churn_rate * 0.25) + ((revenue_lost / 100.0) * 0.2)

      OpenStruct.new(
        id: classification.id,
        tag: classification.tag,
        volume: volume,
        avg_sentiment: avg_sentiment,
        churn_rate: churn_rate,
        revenue_lost: revenue_lost,
        priority_score: priority_score.round(1)
      )
    end.compact.sort_by { |r| -r.priority_score }
  end

  def pareto_classifications
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

    rows.select { |r| r.cum_pct_2.to_f <= 80.00 }
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
    • mencionar de forma clara o mecanismo do erro

    NÃO retorne lista, bullet points ou textos longos.
    NÃO explique o que está fazendo.

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
