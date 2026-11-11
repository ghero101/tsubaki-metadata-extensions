// MyAnimeList Metadata Provider
// Built-in addon for Tsubaki - provides manga metadata via Jikan API (unofficial MAL API)

const BASE_URL = "https://api.jikan.moe/v4";

// Get source information
fn get_source_info() {
    #{
        id: "myanimelist",
        name: "MyAnimeList",
        base_url: "https://myanimelist.net",
        language: "en",
        supported_languages: ["en", "ja"],
        requires_authentication: false,
        is_metadata_provider: true
    }
}

// Normalize string for comparison (lowercase, alphanumeric only)
fn normalize(s) {
    let result = "";
    for ch in s.to_lower().chars() {
        if ch.is_alphanumeric() {
            result += ch;
        }
    }
    result
}

// Map MyAnimeList / Jikan publication status to the canonical UI status set
// (Ongoing / Completed / Hiatus / Cancelled / Upcoming). Returns the raw
// value if it doesn't match — same shape as the AniList plugin's
// normalize_status, kept in sync so UI filters work identically on series
// pulled from either provider.
fn normalize_status(raw) {
    if raw == () || raw == "" { return (); }
    let s = `${raw}`.to_lower();
    if s == "publishing" || s == "currently publishing" { return "Ongoing"; }
    if s == "finished" { return "Completed"; }
    if s == "on hiatus" || s == "hiatus" { return "Hiatus"; }
    if s == "discontinued" { return "Cancelled"; }
    if s == "not yet published" || s == "upcoming" { return "Upcoming"; }
    raw
}

// ----------------------------------------------------------------------------
// Shared item mapping
//
// Search, browse and get_series all map Jikan's manga object through
// item_to_series(), so list results carry the same ids and metadata as a full
// lookup (the browse catalog stores list items as-is).
// ----------------------------------------------------------------------------

// Host pages are 1-based for search and browse alike.
fn page_or_one(page) {
    if page == () || page < 1 { 1 } else { page }
}

// GET a Jikan URL and parse it; () on any network or parse failure.
fn jikan_get(url) {
    let response = "";
    try { response = http_get(url); } catch { return (); }
    if response == () || response == "" { return (); }
    let json = ();
    try { json = json_parse(response); } catch { return (); }
    json
}

// MAL lists people as "Last, First"; flip to "First Last" so names match the
// other providers when the backend merges authors.
fn person_name(raw) {
    let s = `${raw}`.trim();
    let parts = s.split(", ");
    if parts.len() == 2 { return `${parts[1]} ${parts[0]}`; }
    s
}

fn names_of(list) {
    let out = [];
    if list == () { return out; }
    for x in list {
        if x != () && x.name != () && !out.contains(x.name) { out.push(x.name); }
    }
    out
}

// Jikan's manga objects carry no age rating, so derive it from genres.
fn rating_from(item) {
    let all = names_of(item.genres) + names_of(item.explicit_genres);
    for g in all {
        let l = g.to_lower();
        if l == "hentai" || l == "erotica" { return "adult"; }
    }
    for g in all {
        if g.to_lower() == "ecchi" { return "suggestive"; }
    }
    "safe"
}

fn item_to_series(item) {
    let title = if item.title != () { item.title } else { "" };

    let alt_titles = [];
    for v in [item.title_english, item.title_japanese] {
        if v != () && v != "" && v != title && !alt_titles.contains(v) { alt_titles.push(v); }
    }
    if item.title_synonyms != () {
        for v in item.title_synonyms {
            if v != () && v != "" && v != title && !alt_titles.contains(v) { alt_titles.push(v); }
        }
    }

    let cover_url = "";
    if item.images != () {
        let i = item.images;
        if i.webp != () && i.webp.large_image_url != () { cover_url = i.webp.large_image_url; }
        else if i.jpg != () && i.jpg.large_image_url != () { cover_url = i.jpg.large_image_url; }
        else if i.jpg != () && i.jpg.image_url != () { cover_url = i.jpg.image_url; }
    }

    let tags = names_of(item.themes) + names_of(item.demographics);

    let authors = [];
    if item.authors != () {
        for a in item.authors {
            if a.name != () { authors.push(person_name(a.name)); }
        }
    }

    let year = ();
    let start_date = ();
    let end_date = ();
    if item.published != () {
        if item.published.prop != () && item.published.prop.from != () {
            year = item.published.prop.from.year;
        }
        start_date = item.published.from;
        end_date = item.published.to;
    }

    let links = [];
    let external_ids = #{ mal: item.mal_id };
    if item.external != () {
        for l in item.external {
            if l.url == () { continue; }
            links.push(#{ site: l.name, url: l.url });
            // MAL's external links often include the MangaUpdates and AniList
            // pages; lift their ids so the backend can link without searching.
            let u = `${l.url}`;
            if u.contains("anilist.co/manga/") {
                let id = u.split("anilist.co/manga/")[1].split("/")[0];
                if id != "" { external_ids.anilist = id; }
            }
            if u.contains("mangaupdates.com/series") {
                let rest = u.split("mangaupdates.com/series")[1];
                let raw = if rest.starts_with(".html?id=") { rest.split("id=")[1].split("&")[0] } else { rest.split("/")[1] };
                let mu = mangaupdates_id(raw);
                if mu.id != () { external_ids.mangaupdates = mu.id; }
                if mu.legacy != () { external_ids.mangaupdates_legacy = mu.legacy; }
            }
        }
    }

    #{
        id: `${item.mal_id}`,
        title: title,
        alternate_titles: alt_titles,
        description: item.synopsis,
        cover_url: cover_url,
        authors: authors,
        artists: [],
        status: normalize_status(item.status),
        genres: names_of(item.genres) + names_of(item.explicit_genres),
        tags: tags,
        year: year,
        content_rating: rating_from(item),
        chapter_count: item.chapters,
        url: if item.url != () { item.url } else { `https://myanimelist.net/manga/${item.mal_id}` },
        extra: #{
            provider: "mal",
            provider_id: `${item.mal_id}`,
            mal_id: item.mal_id,
            external_ids: external_ids,
            format: item.type,
            score: item.score,
            scored_by: item.scored_by,
            rank: item.rank,
            popularity: item.popularity,
            members: item.members,
            volumes: item.volumes,
            chapters: item.chapters,
            start_date: start_date,
            end_date: end_date,
            serializations: names_of(item.serializations),
            background: item.background,
            links: links
        }
    }
}

// Map a Jikan list response into a SearchResult.
fn list_result(json, page) {
    if json == () || json.data == () {
        return #{ series: [], has_more: false, total: () };
    }
    let series = [];
    for item in json.data { series.push(item_to_series(item)); }
    let p = json.pagination;
    #{
        series: series,
        has_more: if p != () && p.has_next_page == true { true } else { false },
        total: if p != () && p.items != () { p.items.total } else { () },
        current_page: page
    }
}

// Search for manga series
fn search_series(query, page, auth) {
    let p = page_or_one(page);
    let url = `${BASE_URL}/manga?q=${url_encode(query)}&page=${p}&limit=20&order_by=popularity&sort=asc`;
    list_result(jikan_get(url), p)
}

// Get detailed series information by ID or myanimelist.net URL
fn get_series(id_or_url, auth) {
    let id = `${id_or_url}`;
    if id.contains("myanimelist.net/manga/") {
        id = id.split("/manga/")[1].split("/")[0];
    }
    let json = jikan_get(`${BASE_URL}/manga/${id}/full`);
    if json == () || json.data == () { return (); }
    item_to_series(json.data)
}

// Browse: top manga that are currently publishing. (The old listing sorted by
// start_date desc, which surfaced unreleased and junk entries first.)
fn get_latest_updates(page, auth) {
    let p = page_or_one(page);
    list_result(jikan_get(`${BASE_URL}/top/manga?filter=publishing&page=${p}&limit=25`), p)
}

// Most popular manga
fn get_popular(page, auth) {
    let p = page_or_one(page);
    list_result(jikan_get(`${BASE_URL}/top/manga?filter=bypopularity&page=${p}&limit=25`), p)
}

// Resolve manga title to MAL ID
fn resolve_id(title, alt_titles) {
    // Build list of candidate titles to search
    let candidates = [title];
    if alt_titles != () && alt_titles != "" {
        for alt in alt_titles.split(", ") {
            let trimmed = alt.trim();
            if trimmed != "" {
                candidates.push(trimmed);
            }
        }
    }

    for q in candidates {
        let url = `${BASE_URL}/manga?q=${url_encode(q)}&limit=5`;
        let response = http_get(url);
        let json = json_parse(response);

        if json.data != () {
            let target_norm = normalize(q);
            for item in json.data {
                let item_title = item.title;
                let mal_id = item.mal_id;

                if mal_id > 0 && item_title != "" && normalize(item_title) == target_norm {
                    return #{
                        provider: "mal",
                        provider_id: `${mal_id}`,
                        matched_title: item_title
                    };
                }
            }
        }
    }

    ()
}

// ============================================================================
// TRACKING FEATURES - Requires OAuth2 Authentication
// Uses official MAL API v2: https://myanimelist.net/apiconfig/references/api/v2
// ============================================================================

const MAL_API_URL = "https://api.myanimelist.net/v2";

// Reading status mappings
// MAL statuses: reading, completed, on_hold, dropped, plan_to_read
fn map_status_to_mal(status) {
    switch status.to_lower() {
        "reading" | "current" => "reading",
        "completed" | "finished" => "completed",
        "on_hold" | "paused" => "on_hold",
        "dropped" => "dropped",
        "plan_to_read" | "planning" | "planned" => "plan_to_read",
        _ => "reading"
    }
}

fn map_mal_status(mal_status) {
    switch mal_status {
        "reading" => "reading",
        "completed" => "completed",
        "on_hold" => "on_hold",
        "dropped" => "dropped",
        "plan_to_read" => "plan_to_read",
        _ => "unknown"
    }
}

// Get user's manga list
// auth.access_token is required (OAuth2 token)
// status_filter: "reading", "completed", "on_hold", "dropped", "plan_to_read", or () for all
fn get_user_list(status_filter, page, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required. Please connect your MyAnimeList account.", requires_auth: true };
    }

    let limit = 50;
    let offset = (page - 1) * limit;
    let url = `${MAL_API_URL}/users/@me/mangalist?fields=list_status,num_chapters,num_volumes&limit=${limit}&offset=${offset}`;

    if status_filter != () && status_filter != "" && status_filter != "all" {
        url = url + `&status=${map_status_to_mal(status_filter)}`;
    }

    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`
    };

    let response = http_get_with_headers(url, headers);
    let json = json_parse(response);

    if json.error != () {
        return #{ error: json.error, message: json.message };
    }

    let entries = [];
    if json.data != () {
        for item in json.data {
            let node = item.node;
            let list_status = item.list_status;

            entries.push(#{
                manga_id: `${node.id}`,
                title: node.title,
                cover_url: if node.main_picture != () { node.main_picture.large } else { "" },
                status: map_mal_status(list_status.status),
                score: list_status.score,
                chapters_read: list_status.num_chapters_read,
                volumes_read: list_status.num_volumes_read,
                total_chapters: node.num_chapters,
                total_volumes: node.num_volumes,
                is_rereading: list_status.is_rereading,
                reread_count: list_status.num_times_reread,
                start_date: list_status.start_date,
                finish_date: list_status.finish_date,
                updated_at: list_status.updated_at,
                notes: list_status.comments,
                priority: list_status.priority,
                tags: list_status.tags
            });
        }
    }

    let has_next = json.paging != () && json.paging.next != ();

    #{
        entries: entries,
        has_more: has_next,
        total: entries.len(),  // MAL doesn't return total count easily
        current_page: page
    }
}

// Get single manga entry from user's list
fn get_list_entry(manga_id, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    let url = `${MAL_API_URL}/manga/${manga_id}?fields=my_list_status,num_chapters,num_volumes`;
    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`
    };

    let response = http_get_with_headers(url, headers);
    let json = json_parse(response);

    if json.error != () {
        return #{ error: json.error, not_in_list: true };
    }

    let list_status = json.my_list_status;
    if list_status == () {
        return #{ not_in_list: true, manga_id: manga_id };
    }

    #{
        manga_id: `${json.id}`,
        title: json.title,
        status: map_mal_status(list_status.status),
        score: list_status.score,
        chapters_read: list_status.num_chapters_read,
        volumes_read: list_status.num_volumes_read,
        total_chapters: json.num_chapters,
        total_volumes: json.num_volumes,
        is_rereading: list_status.is_rereading,
        reread_count: list_status.num_times_reread,
        start_date: list_status.start_date,
        finish_date: list_status.finish_date,
        updated_at: list_status.updated_at,
        notes: list_status.comments
    }
}

// Update manga entry in user's list
// entry should contain: status, score, chapters_read, volumes_read, etc.
fn update_list_entry(manga_id, entry, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    let url = `${MAL_API_URL}/manga/${manga_id}/my_list_status`;
    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`,
        "Content-Type": "application/x-www-form-urlencoded"
    };

    // Build form data
    let form_data = [];

    if entry.status != () && entry.status != "" {
        form_data.push(`status=${map_status_to_mal(entry.status)}`);
    }

    if entry.score != () {
        // MAL score is 0-10
        let score = entry.score;
        if score < 0 { score = 0; }
        if score > 10 { score = 10; }
        form_data.push(`score=${score}`);
    }

    if entry.chapters_read != () {
        form_data.push(`num_chapters_read=${entry.chapters_read}`);
    }

    if entry.volumes_read != () {
        form_data.push(`num_volumes_read=${entry.volumes_read}`);
    }

    if entry.is_rereading != () {
        form_data.push(`is_rereading=${entry.is_rereading}`);
    }

    if entry.reread_count != () {
        form_data.push(`num_times_reread=${entry.reread_count}`);
    }

    if entry.start_date != () && entry.start_date != "" {
        form_data.push(`start_date=${entry.start_date}`);
    }

    if entry.finish_date != () && entry.finish_date != "" {
        form_data.push(`finish_date=${entry.finish_date}`);
    }

    if entry.notes != () {
        form_data.push(`comments=${url_encode(entry.notes)}`);
    }

    if entry.priority != () {
        // 0 = Low, 1 = Medium, 2 = High
        form_data.push(`priority=${entry.priority}`);
    }

    let body = "";
    let first = true;
    for part in form_data {
        if first { body = part; first = false; }
        else { body = body + "&" + part; }
    }

    let response = http_patch_form(url, body, headers);
    let json = json_parse(response);

    if json.error != () {
        return #{ success: false, error: json.error, message: json.message };
    }

    #{
        success: true,
        manga_id: manga_id,
        status: map_mal_status(json.status),
        score: json.score,
        chapters_read: json.num_chapters_read,
        volumes_read: json.num_volumes_read,
        updated_at: json.updated_at
    }
}

// Remove manga from user's list
fn remove_list_entry(manga_id, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    let url = `${MAL_API_URL}/manga/${manga_id}/my_list_status`;
    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`
    };

    let response = http_delete_with_headers(url, headers);

    // MAL returns 200 on success, 404 if not in list
    if response.status_code == 200 || response.status_code == 204 {
        return #{ success: true, manga_id: manga_id };
    }

    let json = json_parse(response);
    if json.error != () {
        return #{ success: false, error: json.error };
    }

    #{ success: true, manga_id: manga_id }
}

// Sync reading progress from local to MAL
// progress should contain: manga_id, chapters_read, volumes_read, status (optional)
fn sync_progress(manga_id, progress, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    // First get current entry to compare
    let current = get_list_entry(manga_id, auth);

    let entry = #{
        chapters_read: progress.chapters_read,
        volumes_read: progress.volumes_read
    };

    // Auto-set status based on progress if not specified
    if progress.status != () {
        entry.status = progress.status;
    } else if current.not_in_list == true {
        // New entry - set to reading
        entry.status = "reading";
    } else if progress.chapters_read != () && current.total_chapters != () && progress.chapters_read >= current.total_chapters {
        // Completed all chapters
        entry.status = "completed";
    }

    // Auto-set start date if newly reading
    if current.not_in_list == true && entry.status == "reading" {
        let today = get_current_date();
        entry.start_date = today;
    }

    // Auto-set finish date if completed
    if entry.status == "completed" && (current.status != "completed" || current.not_in_list == true) {
        let today = get_current_date();
        entry.finish_date = today;
    }

    update_list_entry(manga_id, entry, auth)
}

// Get recommendations for a series from MAL
fn get_recommendations(manga_id, auth) {
    // Using Jikan API for recommendations (doesn't require auth)
    let url = `${BASE_URL}/manga/${manga_id}/recommendations`;
    let response = http_get(url);
    let json = json_parse(response);

    let recommendations = [];

    if json.data != () {
        for item in json.data {
            let entry = item.entry;
            let cover_url = "";
            if entry.images != () && entry.images.jpg != () {
                cover_url = entry.images.jpg.large_image_url;
                if cover_url == () {
                    cover_url = entry.images.jpg.image_url;
                }
            }

            recommendations.push(#{
                id: `${entry.mal_id}`,
                title: entry.title,
                cover_url: cover_url,
                url: entry.url,
                votes: item.votes
            });
        }
    }

    #{
        recommendations: recommendations,
        total: recommendations.len()
    }
}


// Login function - validates client credentials are present
// MAL uses OAuth2 for user tracking, client credentials enable authenticated API access
fn login(credentials) {
    let client_id = if credentials.mal_client_id != () { credentials.mal_client_id } else { "" };
    let client_secret = if credentials.mal_client_secret != () { credentials.mal_client_secret } else { "" };

    if client_id == "" {
        return #{
            success: false,
            error: "MAL Client ID is required. Get it from https://myanimelist.net/apiconfig"
        };
    }

    // MAL client_secret is optional when using PKCE
    // So we just validate client_id is present

    // Client credentials are valid - they will be used for OAuth2 authorization code flow
    // Return success so the credentials are stored for later OAuth use
    #{
        success: true,
        session_token: client_id,  // Store client_id as session marker
        message: "MAL credentials validated. Use OAuth to authorize user tracking."
    }
}

// MangaUpdates ids: current pages use a base36 slug ("pb8uwds") that encodes
// the numeric API id (55099564912); old "series.html?id=33" ids are a separate
// legacy numbering the v1 API doesn't accept. Returns #{ id } for a slug, or
// #{ legacy } for an all-digit legacy id.
fn mangaupdates_id(raw) {
    let s = `${raw}`.trim().to_lower();
    if s == "" { return #{}; }
    let all_digits = true;
    for c in s.chars() { if c < '0' || c > '9' { all_digits = false; break; } }
    if all_digits { return #{ legacy: s }; }
    let n = 0;
    for c in s.chars() {
        let v = if c >= '0' && c <= '9' { c.to_int() - 48 } else if c >= 'a' && c <= 'z' { c.to_int() - 87 } else { return #{}; };
        n = n * 36 + v;
    }
    #{ id: `${n}` }
}
