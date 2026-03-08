class PagesController < ApplicationController
  skip_before_action :authenticate_user!, only: [:home]

  def dashboard
    # Date range
    @start_date =
      params[:start_date]&.to_date ||
      Conversation.minimum(:occurred_on)

    @end_date =
      params[:end_date]&.to_date ||
      Conversation.maximum(:occurred_on)

    base_scope = Conversation.where(occurred_on: @start_date..@end_date)

    # KPI 1: Total Conversations in period
    @total_conversations = base_scope.count

    # KPI 2: Critical Sentiment - conversations with "crítico" or "frustrado"
    @critical_sentiment_count = base_scope
      .where(sentiment_label: ["crítico", "frustrado"])
      .count

    # KPI 3: Revenue at Risk - MRR sum of at_risk customers with conversations in period
    at_risk_customer_ids = base_scope
      .where.not(customer_id: nil)
      .joins("INNER JOIN customers ON customers.id = conversations.customer_id")
      .where(customers: { status: "at_risk" })
      .distinct
      .pluck(:customer_id)

    @revenue_at_risk = at_risk_customer_ids.any? ? Customer.where(id: at_risk_customer_ids).sum(:mrr) : 0

    # Top 3 Problems by Impact (priority_score)
    @top_problems = build_top_problems(base_scope)

    # Button state
    range_type = params[:range_type]
    @active_preset =
      range_type == "preset" ? active_preset(@start_date, @end_date) : nil
    @custom_range_active =
      range_type == "custom"

    # Chart grouping based on time span
    range_days = (@end_date - @start_date).to_i

    if range_days <= 7
      group_sql    = "occurred_on::date"
      label_format = "%d %b"
    elsif range_days <= 31
      group_sql    = "DATE_TRUNC('week', occurred_on)::date"
      label_format = "Week of %d %b"
    elsif range_days <= 92
      group_sql    = "DATE_TRUNC('month', occurred_on)::date"
      label_format = "%b %Y"
    else
      group_sql    = "DATE_TRUNC('week', occurred_on)::date"
      label_format = "Week of %d %b"
    end

    @chart_series = Conversation
      .joins(:category)
      .where(occurred_on: @start_date..@end_date)
      .group(
        Arel.sql(group_sql),
        Arel.sql("categories.name")
      )
      .order(Arel.sql(group_sql))
      .count

    periods = @chart_series.keys.map(&:first).uniq.sort
    categories = @chart_series.keys.map(&:last).uniq

    labels = periods.map { |p| p.strftime(label_format) }

    datasets = categories.map do |category|
      {
        label: category.to_s.humanize.titleize,
        data: periods.map { |p| @chart_series[[p, category]] || 0 },
        color: "--#{category.parameterize}"
      }
    end

    @chart_data = {
      labels: labels,
      datasets: datasets
    }
  end

  def home
  end

  private

  def build_top_problems(base_scope)
    classification_ids = base_scope.where.not(classification_id: nil)
                                    .group(:classification_id)
                                    .order(Arel.sql("COUNT(*) DESC"))
                                    .limit(10)
                                    .count
                                    .keys

    classifications = Classification.where(id: classification_ids)

    classifications.map do |classification|
      convos = base_scope.where(classification_id: classification.id)
      volume = convos.count
      next if volume.zero?

      avg_sentiment = convos.where.not(sentiment_score: nil).average(:sentiment_score)&.round(1) || 0

      customer_ids = convos.where.not(customer_id: nil).pluck(:customer_id).uniq
      revenue_lost = customer_ids.any? ? Customer.where(id: customer_ids, status: "churned").sum(:mrr) : 0

      churn_rate = 0
      if customer_ids.any?
        total_c = Customer.where(id: customer_ids).count
        churned_c = Customer.where(id: customer_ids, status: "churned").count
        churn_rate = total_c.positive? ? ((churned_c * 100.0) / total_c).round(1) : 0
      end

      priority_score = (volume * 0.3) + (avg_sentiment * 0.25) + (churn_rate * 0.25) + ((revenue_lost / 100.0) * 0.2)

      OpenStruct.new(
        id: classification.id,
        tag: classification.tag,
        volume: volume,
        avg_sentiment: avg_sentiment,
        revenue_lost: revenue_lost,
        priority_score: priority_score.round(1)
      )
    end.compact.sort_by { |r| -r.priority_score }.first(3)
  end

  def active_preset(start_date, end_date)
    today = Date.today

    return :last_7_days if end_date == today && start_date >= 7.days.ago.to_date
    return :last_month  if end_date == today && start_date >= 1.month.ago.to_date
    return :last_quarter if end_date == today && start_date >= 3.months.ago.to_date

    nil
  end
end
