// Alle Texte, die Panels und Knöpfe zeigen, stehen hier (ui-spec §7).
//
// Schlüssel -> { de, en, regel }
//   de    Anzeigetext (Deutsch, fest)
//   en    Regelbegriff für den Tooltip (Englisch, wie im Regelwerk oder in der Engine)
//   regel Verweis auf das Regelwerk (input/18OE_Rulebook_v_1.0.txt), "—" wenn keiner
//
// Schlüsselnamen:
//   round.<type>          meta.round.type (lib/oe/view.rb)
//   step.<ClassName>      Schrittklassen aus lib/engine/game/g_18_oe/step/ bzw. lib/engine/step/
//   action.<type>         Aktionstyp = Dateiname in lib/engine/action/ (Action::Base.type)
//   tier.<stufe>          Firmenstufe (type in lib/engine/game/g_18_oe/entities.rb)
//   dividend.<kind>       Dividendenart nach Regelwerk §11.4
//   error.<code>          Fehlercode des Servers (lib/oe/games_api.rb) bzw. "network" (web/api.ts)
//   ref.<§>               Regelverweis auf einen Abschnitt
//
// Hinweis: Die englischen Begriffe der Stufen (Minor, Regional, Major, National) sind
// Eigennamen des Spiels. Die deutschen Anzeigenamen sind dieselben, bis der Eigentümer
// eigene Begriffe wählt (Annahme, siehe Issue #161).

export interface Entry {
  readonly de: string;
  readonly en: string;
  readonly regel: string;
}

const e = (de: string, en: string, regel: string): Entry => ({ de, en, regel });

export const TEXT: Readonly<Record<string, Entry>> = {
  // --- Rundentypen -------------------------------------------------------
  "round.auction": e("Auktion", "Auction Railroad Phase", "§7"),
  "round.concession": e("Konzessionsphase", "Concession Railroad Phase", "§5.1.2, §8.1"),
  "round.stock": e("Aktienrunde", "Stock Round", "§10"),
  "round.operating": e("Betriebsrunde", "Operating Round", "§11"),
  "round.consolidation": e("Konsolidierungsrunde", "Consolidation Railroad Phase", "§10.6"),

  // --- Schritte (g_18_oe/step/*.rb, lib/engine/step/*.rb laut ui-spec §4.1) --
  "step.WaterfallAuction": e("Auktion (Wasserfall)", "Waterfall auction", "§7"),
  "step.Concession": e("Konzession vergeben", "Concession", "§6.3, §8.1"),
  "step.BuySellParShares": e("Aktien kaufen oder verkaufen", "Buy or sell shares", "§10, §11.7"),
  "step.BuyTrain": e("Zug kaufen", "Buy train", "§11.6"),
  "step.ReserveShare": e("Reservierte Aktie", "Reserved share", "§9"),
  "step.Dividend": e("Dividende wählen", "Dividend", "§11.4"),
  "step.HomeToken": e("Heimatstation setzen", "Home token", "§9.3, §11.2"),
  "step.Token": e("Station setzen", "Place token", "§11.2"),
  "step.SpecialToken": e("Sonderstation setzen", "Special token", "§11.2"),
  "step.Track": e("Gleis legen", "Lay track", "§11.1"),
  "step.Route": e("Fahrt", "Run routes", "§11.3"),
  "step.OrientExpressBonus": e("Orient-Express-Bonus", "Orient Express bonus", "§12, §12.2"),
  "step.IssueShares": e("Aktien ausgeben", "Issue shares", "§4"),
  "step.MergeMinor": e("Minor einbringen", "Merge minor", "§10.5"),
  "step.MergeToken": e("Station beim Zusammenschluss", "Merge token", "§10.5, §10.6"),
  "step.MergeOffer": e("Angebot beim Zusammenschluss", "Merge offer", "§10.6"),
  "step.MergeDiscardTrain": e("Zug beim Zusammenschluss abwerfen", "Discard train on merger", "§10.5, §10.6"),
  "step.Consolidate": e("Konsolidierung", "Consolidation", "§10.6"),
  "step.DiscardTrain": e("Zug abwerfen", "Discard train", "§11.6"),
  "step.Bankrupt": e("Bankrott", "Bankruptcy", "§11.6.5"),
  "step.Exchange": e("Tausch", "Exchange", "§11"),

  // --- Aktionstypen (lib/engine/action/*.rb, ohne base.rb) ------------------
  "action.acquire_company": e("Privat übernehmen", "Acquire company", "§14"),
  "action.assign": e("Zuweisen", "Assign", "§14"),
  "action.bankrupt": e("Bankrott erklären", "Bankrupt", "§11.6.5"),
  "action.bid": e("Gebot abgeben", "Bid", "§7"),
  "action.blind_bid": e("Verdecktes Gebot", "Blind bid", "§7"),
  "action.borrow_train": e("Zug leihen", "Borrow train", "§11.6"),
  "action.buy_company": e("Privat kaufen", "Buy company", "§14, §15"),
  "action.buy_corporation": e("Gesellschaft kaufen", "Buy corporation", "§9"),
  "action.buy_power": e("Fähigkeit kaufen", "Buy power", "§14, §15"),
  "action.buy_shares": e("Aktien kaufen", "Buy shares", "§10.2"),
  "action.buy_token": e("Station kaufen", "Buy token", "§11.5"),
  "action.buy_train": e("Zug kaufen", "Buy train", "§11.6"),
  "action.choose_ability": e("Fähigkeit wählen", "Choose ability", "§14, §15"),
  "action.choose": e("Auswahl treffen", "Choose", "—"),
  "action.claim_hex_token": e("Feldstation beanspruchen", "Claim hex token", "§11.2"),
  "action.combined_trains": e("Züge kombinieren", "Combined trains", "§12.1"),
  "action.convert": e("Umwandeln", "Convert", "§9"),
  "action.corporate_buy_company": e("Gesellschaft kauft Privat", "Corporate buy company", "§14"),
  "action.corporate_buy_shares": e("Gesellschaft kauft Aktien", "Corporate buy shares", "§10.2"),
  "action.corporate_sell_company": e("Gesellschaft verkauft Privat", "Corporate sell company", "§14"),
  "action.corporate_sell_shares": e("Gesellschaft verkauft Aktien", "Corporate sell shares", "§10.1"),
  "action.credit_mobilier": e("Credit Mobilier", "Credit Mobilier", "§14"),
  "action.destination_connection": e("Zielverbindung", "Destination connection", "§11.3"),
  "action.discard_train": e("Zug abwerfen", "Discard train", "§11.6"),
  "action.dividend": e("Dividende wählen", "Dividend", "§11.4"),
  "action.double_head_trains": e("Doppeltraktion", "Double-head trains", "§11.3.8"),
  "action.end_game": e("Spielende", "End game", "§13"),
  "action.failed_merge": e("Zusammenschluss gescheitert", "Failed merge", "§10.5"),
  "action.hex_token": e("Feldstation setzen", "Hex token", "§11.2"),
  "action.lay_tile": e("Gleis legen", "Lay tile", "§11.1"),
  "action.log": e("Protokolleintrag", "Log", "—"),
  "action.manual_close_company": e("Privat manuell schließen", "Manual close company", "§14"),
  "action.merge": e("Zusammenschluss", "Merge", "§10.5, §10.6"),
  "action.message": e("Nachricht", "Message", "—"),
  "action.move_bid": e("Gebot verschieben", "Move bid", "§7"),
  "action.offer": e("Angebot", "Offer", "§10.6"),
  "action.par": e("Nennwert festlegen", "Par", "§9.2, §9.3"),
  "action.pass": e("Passen", "Pass", "—"),
  "action.payoff_debt": e("Schulden tilgen", "Pay off debt", "—"),
  "action.payoff_loan": e("Kredit tilgen", "Pay off loan", "—"),
  "action.payoff_player_debt_partial": e("Spielerschuld teilweise tilgen", "Pay off part of player debt", "—"),
  "action.payoff_player_debt": e("Spielerschuld tilgen", "Pay off player debt", "—"),
  "action.place_token": e("Station setzen", "Place token", "§11.2"),
  "action.program_auction_bid": e("Vorprogrammiertes Auktionsgebot", "Programmed auction bid", "—"),
  "action.program_buy_shares": e("Vorprogrammierter Aktienkauf", "Programmed share purchase", "—"),
  "action.program_close_pass": e("Vorprogrammiertes Passen zum Schließen", "Programmed close pass", "—"),
  "action.program_disable": e("Vorprogrammierung aus", "Programmed disable", "—"),
  "action.program_enable": e("Vorprogrammierung ein", "Programmed enable", "—"),
  "action.program_harzbahn_draft_pass": e("Vorprogrammiertes Passen bei der Auswahl", "Programmed draft pass", "—"),
  "action.program_independent_mines": e("Vorprogrammierte unabhängige Minen", "Programmed independent mines", "—"),
  "action.program_merger_pass": e("Vorprogrammiertes Passen beim Zusammenschluss", "Programmed merger pass", "—"),
  "action.program_share_pass": e("Vorprogrammiertes Passen bei Aktien", "Programmed share pass", "—"),
  "action.purchase_train": e("Zug erwerben", "Purchase train", "§11.6"),
  "action.reassign_trains": e("Züge neu zuweisen", "Reassign trains", "§11.6"),
  "action.redo": e("Wiederholen", "Redo", "—"),
  "action.remove_border": e("Grenze entfernen", "Remove border", "§11.1"),
  "action.remove_hex_token": e("Feldstation entfernen", "Remove hex token", "§11.2"),
  "action.remove_token": e("Station entfernen", "Remove token", "§11.2"),
  "action.respond": e("Antworten", "Respond", "—"),
  "action.run_routes": e("Fahrt", "Run routes", "§11.3"),
  "action.scrap_train": e("Zug verschrotten", "Scrap train", "§11.6"),
  "action.select_multiple_companies": e("Mehrere Privates wählen", "Select multiple companies", "§14"),
  "action.sell_company": e("Privat verkaufen", "Sell company", "§14"),
  "action.sell_shares": e("Aktien verkaufen", "Sell shares", "§10.1"),
  "action.sell_train": e("Zug verkaufen", "Sell train", "§11.6"),
  "action.short": e("Leerverkauf", "Short", "—"),
  "action.skip": e("Überspringen", "Skip", "—"),
  "action.special_buy": e("Sonderkauf", "Special buy", "§14, §15"),
  "action.split": e("Gesellschaft teilen (von keinem Schritt genutzt)", "Split (corporation)", "—"),
  "action.swap_train": e("Zug tauschen", "Swap train", "§11.6"),
  "action.switch_trains": e("Züge umschalten", "Switch trains", "§11.6"),
  "action.take_loan": e("Kredit aufnehmen", "Take loan", "—"),
  "action.undo": e("Rückgängig", "Undo", "—"),
  "action.use_graph": e("Graph verwenden", "Use graph", "—"),
  "action.view_merge_options": e("Zusammenschluss-Optionen ansehen", "View merge options", "§10.6"),

  // --- Firmenstufen (Annahme: Eigennamen, siehe Kopfkommentar) --------------
  "tier.minor": e("Minor", "Minor", "§6.2, §15"),
  "tier.regional": e("Regional", "Regional", "§9.2"),
  "tier.major": e("Major", "Major", "§9.3"),
  "tier.national": e("National", "National", "§9.4"),

  // --- Dividendenarten (Regelwerk §11.4) ------------------------------------
  "dividend.withhold": e("Einbehalten", "Withhold the revenue", "§11.4"),
  "dividend.half": e("Hälfte ausschütten", "Pay half-revenue as dividends", "§11.4"),
  "dividend.payout": e("Alles ausschütten", "Pay all revenue as dividends", "§11.4"),

  // --- Gründe für Ungültiges (ui-spec §3.5: nur diese Fälle, sonst Standardtext) --
  "invalid.cash": e("Zu wenig Bargeld", "Not enough cash", "—"),
  "invalid.certificate_limit": e("Zertifikatslimit erreicht", "Certificate limit reached", "§2.2.7"),
  "invalid.no_build_points": e("Keine Baupunkte mehr", "No tile placements left", "§11.1"),
  "invalid.no_token": e("Kein freier Token", "No token available", "§11.2"),
  "invalid.no_train": e("Kein Zug dieser Art im Depot", "No train of this type in the depot", "§11.6"),
  "invalid.tile_unavailable": e("Kachel nicht vorrätig", "Tile not available", "§11.1.2"),
  "invalid.phase": e("Nicht in dieser Phase (Kachelfarbe)", "Not allowed in this phase (tile colour)", "§5"),
  "invalid.default": e("Jetzt nicht möglich", "Not possible now", "—"),

  // --- Fehlercodes (lib/oe/games_api.rb, app.rb; "network" in web/api.ts) ----
  "error.bad_request": e("Ungültige Anfrage", "Bad request", "—"),
  "error.login_required": e("Bitte anmelden", "Login required", "—"),
  "error.forbidden": e("Keine Berechtigung", "Forbidden", "—"),
  "error.not_your_turn": e("Du bist nicht am Zug", "Not your turn", "—"),
  "error.not_found": e("Nicht gefunden", "Not found", "—"),
  "error.conflict": e("Die Partie hat sich inzwischen geändert", "Conflict (stale sequence)", "—"),
  "error.rejected": e("Aktion nicht erlaubt", "Action rejected", "—"),
  "error.invalid_seats": e("Ungültige Sitzplätze", "Invalid seats", "—"),
  "error.game_limit": e("Zu viele aktive Partien", "Game limit reached", "—"),
  "error.internal_error": e("Interner Fehler", "Internal error", "—"),
  "error.network": e("Keine Verbindung zum Server", "Network error", "—"),
  "error.invalid_login": e("Anmeldung fehlgeschlagen", "Invalid login or password", "—"),
  "error.rate_limited": e("Zu viele Versuche", "Too many attempts", "—"),
  "error.invalid_invite": e("Einladungscode falsch", "Invalid invite code", "—"),
  "error.invalid_name": e("Name ungültig", "Invalid name", "—"),
  "error.invalid_email": e("E-Mail-Adresse ungültig", "Invalid e-mail address", "—"),
  "error.invalid_password": e("Passwort ungültig", "Invalid password", "—"),
  "error.name_taken": e("Name vergeben", "Name already taken", "—"),
  "error.registration_failed": e("Registrierung nicht möglich", "Registration failed", "—"),

  // --- Zugang: Anmelden und Registrieren (#210) -----------------------------
  "access.title_login": e("Anmelden", "Log in", "—"),
  "access.title_register": e("Registrieren", "Register", "—"),
  "access.login_label": e("E-Mail oder Name", "E-mail or name", "—"),
  "access.name_label": e("Name", "Name", "—"),
  "access.email_label": e("E-Mail", "E-mail", "—"),
  "access.password_label": e("Passwort", "Password", "—"),
  "access.code_label": e("Einladungscode", "Invite code", "—"),
  "access.submit_login": e("Anmelden", "Log in", "—"),
  "access.submit_register": e("Registrieren", "Register", "—"),
  "access.to_register": e("Noch kein Konto? Registrieren", "No account yet? Register", "—"),
  "access.to_login": e("Schon ein Konto? Anmelden", "Already registered? Log in", "—"),
  "access.hint_name": e("2 bis 30 Zeichen, ohne @", "2 to 30 characters, no @", "—"),
  "access.hint_password": e("Mindestens 8 Zeichen", "At least 8 characters", "—"),
  "access.hint_code": e("Den Code hast du vom Spielleiter erhalten.", "The code comes from the host", "—"),
  "access.busy": e("Einen Moment …", "Please wait", "—"),
  // Fehlermeldungen je Server-Code oder Client-Prüfung
  "access.err_required": e("Bitte alle Felder ausfüllen.", "All fields are required", "—"),
  "access.err_email_form": e("Das sieht nicht nach einer E-Mail-Adresse aus.", "Not an e-mail address", "—"),
  "access.err_password_short": e("Das Passwort ist zu kurz, mindestens 8 Zeichen.", "Password too short", "—"),
  "access.err_invalid_login": e("E-Mail, Name oder Passwort stimmt nicht.", "Wrong login or password", "—"),
  "access.err_rate_limited": e("Zu viele Versuche. Bitte in etwa 15 Minuten noch einmal versuchen.", "Too many attempts", "—"),
  "access.err_invalid_invite": e("Der Einladungscode ist falsch.", "Wrong invite code", "—"),
  "access.err_invalid_name": e("Der Name ist ungültig: 2 bis 30 Zeichen, ohne @.", "Invalid name", "—"),
  "access.err_invalid_email": e("Die E-Mail-Adresse ist ungültig.", "Invalid e-mail address", "—"),
  "access.err_invalid_password": e("Das Passwort ist ungültig: 8 bis 200 Zeichen.", "Invalid password", "—"),
  "access.err_name_taken": e("Dieser Name ist schon vergeben. Bitte einen anderen wählen.", "Name already taken", "—"),
  "access.err_registration_failed": e("Mit diesen Angaben ist keine Registrierung möglich. Bist du schon registriert? Dann melde dich an.", "Registration not possible with these details", "—"),
  "access.err_network": e("Keine Verbindung zum Server. Bitte noch einmal versuchen.", "Network error", "—"),
  "access.err_other": e("Das hat nicht geklappt: {message}", "Failed: {message}", "—"),

  // --- Meldungen der Fehlerbehandlung (ui-spec §3.6, #162) -------------------
  // `{n}` und `{message}` ersetzt der Code; der Engine-Text selbst bleibt unverändert englisch.
  "msg.rejected": e("Nicht erlaubt: {message}", "Not allowed: {message}", "—"),
  "msg.conflict": e("Der Spielstand hat sich geändert, bitte neu wählen.", "State changed, choose again", "—"),
  "msg.not_your_turn": e("Du bist gerade nicht am Zug.", "You are not to act right now", "—"),
  "msg.bad_request": e("Programmfehler: {message}", "Program error: {message}", "—"),
  "msg.server_error": e("Serverfehler: {message}", "Server error: {message}", "—"),
  "msg.network_band": e("Keine Verbindung, neuer Versuch in {n} s", "No connection, retrying in {n} s", "—"),
  "msg.network_retry": e("Jetzt", "Retry now", "—"),
  "msg.network_action": e("Keine Verbindung, die Aktion wurde nicht gesendet. Auswahl bleibt.", "No connection, action not sent", "—"),
  "msg.not_found_title": e("Partie nicht gefunden", "Game not found", "—"),
  "msg.not_found_link": e("Zur Liste der Partien", "Back to the list of games", "—"),
  "msg.sending": e("…", "Waiting for the server", "—"),

  // --- Regelverweise ---------------------------------------------------------
  "ref.§4": e("Regelwerk §4: Aktienmarkt", "Rulebook section 4: Stock Market", "§4"),
  "ref.§4.4": e("Regelwerk §4.4: Kursmarke", "Rulebook section 4.4: Share Value Marker Movement", "§4.4"),
  "ref.§5.1.2": e("Regelwerk §5.1.2: Konzessionsphase", "Rulebook section 5.1.2: Concession Railroad Phase", "§5.1.2"),
  "ref.§6.2": e("Regelwerk §6.2: Minors", "Rulebook section 6.2: Minors", "§6.2"),
  "ref.§6.3": e("Regelwerk §6.3: Konzessionen", "Rulebook section 6.3: Concessions", "§6.3"),
  "ref.§7": e("Regelwerk §7: Auktionsphase", "Rulebook section 7: Auction Railroad Phase", "§7"),
  "ref.§8.1": e("Regelwerk §8.1: Zugphase 1, Konzessionen", "Rulebook section 8.1: Train Phase 1 concession actions", "§8.1"),
  "ref.§8.2": e("Regelwerk §8.2: Regional/Minor-Phase", "Rulebook section 8.2: Regional/Minor Railroad Phase", "§8.2"),
  "ref.§9": e("Regelwerk §9: Gründung und Zusammenschluss", "Rulebook section 9: Railroad Formation and Consolidation", "§9"),
  "ref.§10": e("Regelwerk §10: Aktienrunden", "Rulebook section 10: Stock Rounds", "§10"),
  "ref.§10.6": e("Regelwerk §10.6: Konsolidierungsphase", "Rulebook section 10.6: Consolidation Railroad Phase", "§10.6"),
  "ref.§11": e("Regelwerk §11: Betriebsrunden", "Rulebook section 11: Operating Rounds", "§11"),
  "ref.§11.4": e("Regelwerk §11.4: Einnahmen zahlen, teilen oder einbehalten", "Rulebook section 11.4: Pay, Split, or Hold Revenues", "§11.4"),
  "ref.§12": e("Regelwerk §12: Orient Express", "Rulebook section 12: The Orient Express", "§12"),
  "ref.§13": e("Regelwerk §13: Spielende", "Rulebook section 13: Ending the Game", "§13"),
  "ref.§14": e("Regelwerk §14: Privates (Anhang A)", "Rulebook section 14: Appendix A: Privates", "§14"),
  "ref.§15": e("Regelwerk §15: Minors (Anhang B)", "Rulebook section 15: Appendix B: Minors", "§15"),
};

// Liefert den Eintrag zu einem Schlüssel. Ein unbekannter Schlüssel fällt auf den
// Schlüssel selbst zurück, damit die Oberfläche nicht abbricht; der Test stellt sicher,
// dass alle Schlüssel aus Engine und Spec vorhanden sind.
export function txt(key: string): Entry {
  return TEXT[key] ?? { de: key, en: key, regel: "—" };
}
