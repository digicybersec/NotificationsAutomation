# ============================================================================
# ÉTAGE 1 — Transport rule de détection + déclenchement (Exchange Online)
# Détecte spf=fail / dkim=fail sur mail externe entrant, délivre + bannière,
# BCC une copie vers la boîte de service que le Logic App surveille.
# ============================================================================

Connect-ExchangeOnline

New-TransportRule -Name "SEC-AuthFail-Detect-Trigger" `
  -Priority 1 `
  -FromScope NotInOrganization `
  -SentToScope InOrganization `
  -HeaderMatchesMessageHeader "Authentication-Results" `
  -HeaderMatchesPatterns "spf=fail","dkim=fail" `
  -BlindCopyTo "svc-authfail@yourdomain.com" `
  -SetHeaderName "X-SO-AuthFail" `
  -SetHeaderValue "True" `
  -GenerateIncidentReport "soc@yourdomain.com" `
  -IncidentReportContent Sender,Recipients,Subject,Headers `
  -ApplyHtmlDisclaimerLocation Prepend `
  -ApplyHtmlDisclaimerText "<div style='border:2px solid #c00;padding:8px;background:#fff3f3;font-family:sans-serif'>⚠️ <b>Expéditeur non authentifié (SPF/DKIM).</b> Vérifiez l'identité avant de répondre, cliquer ou ouvrir une pièce jointe.</div>" `
  -ApplyHtmlDisclaimerFallbackAction Wrap
