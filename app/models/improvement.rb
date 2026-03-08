class Improvement < ApplicationRecord
  belongs_to :user
  belongs_to :classification


IMPROVEMENT_PROMPT = <<~PROMPT
As conversas abaixo são do mesmo problema.

Gere apenas títulos curtos (máx. 10 palavras) para ações de melhoria.
Não explique nada. Não escreva frases longas. Apenas títulos.

Formato obrigatório:

Curto Prazo:
- <título>
- <título>

Médio Prazo:
- <título>
- <título>

Longo Prazo:
- <título>
- <título>
PROMPT

PRESCRIPTIVE_PROMPT = <<~PROMPT
Você é um consultor estratégico de Customer Success com foco em redução de churn e retenção de receita.

Analise os dados abaixo sobre um problema específico de atendimento e gere um roadmap prescritivo de ações.

DADOS DO PROBLEMA:
%{context_data}

FORMATO OBRIGATÓRIO DE RESPOSTA:

Curto Prazo:
- [Ação específica e implementável]
Justificativa: [baseada nos dados de sentimento e churn fornecidos]
Impacto estimado: [referência concreta à receita em risco ou perdida]

- [Ação específica e implementável]
Justificativa: [baseada nos dados]
Impacto estimado: [referência financeira]

Médio Prazo:
- [Ação específica]
Justificativa: [baseada nos dados]
Impacto estimado: [referência financeira]

- [Ação específica]
Justificativa: [baseada nos dados]
Impacto estimado: [referência financeira]

Longo Prazo:
- [Ação estratégica]
Justificativa: [baseada nos dados]
Impacto estimado: [referência financeira]

- [Ação estratégica]
Justificativa: [baseada nos dados]
Impacto estimado: [referência financeira]

REGRAS:
- Cada ação deve ser específica e implementável, não genérica.
- As justificativas devem citar números dos dados fornecidos.
- Os impactos devem referenciar valores de receita reais.
- Responda em português.
- Não inclua introduções ou explicações fora do formato.
PROMPT

end
