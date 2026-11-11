// MangaUpdates Metadata Provider (Rhai)
// API-based metadata provider for mangaupdates.com
// Provides detailed series information, reviews, and release tracking
//
// API Docs: https://api.mangaupdates.com/
//
// Available APIs:
//   http_get(url) -> string
//   http_post_json(url, body) -> string
//   json_parse(text) -> Dynamic
//   json_stringify(value) -> string
//   url_encode(text) -> string

const API_BASE = "https://api.mangaupdates.com/v1";

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "mangaupdates-rhai",
        name: "MangaUpdates",
        base_url: API_BASE,
        language: "en",
        supported_languages: ["en"],
        requires_authentication: false,
        capability_level: "http_only",
        addon_type: "metadata"
    }
}

// ----------------------------------------------------------------------------
// Shared record mapping: search results, browse listings and get_series all go
// through record_to_series(), so list items carry the same ids and metadata as
// a full lookup (the browse catalog stores list items as-is).
// ----------------------------------------------------------------------------

fn page_or_one(page) {
    if page == () || page < 1 { 1 } else { page }
}

fn mu_post(path, body) {
    let response = "";
    try { response = http_post_json(`${API_BASE}${path}`, json_stringify(body)); } catch { return (); }
    if response == () || response == "" { return (); }
    let data = ();
    try { data = json_parse(response); } catch {}
    data
}

fn mu_get(path) {
    let response = "";
    try { response = http_get(`${API_BASE}${path}`); } catch { return (); }
    if response == () || response == "" { return (); }
    let data = ();
    try { data = json_parse(response); } catch {}
    data
}

// "113 Volumes (Ongoing)" / "Complete" / "4 Volumes (Hiatus)" -> canonical.
fn map_status(raw, completed) {
    if completed == true { return "Completed"; }
    if raw == () || raw == "" { return (); }
    let s = `${raw}`.to_lower();
    if s.contains("ongoing") { return "Ongoing"; }
    if s.contains("hiatus") { return "Hiatus"; }
    if s.contains("cancel") || s.contains("discontinued") || s.contains("dropped") { return "Cancelled"; }
    if s.contains("complete") { return "Completed"; }
    raw
}

fn rating_from_genres(genres) {
    let adult = false;
    let mature = false;
    for g in genres {
        let l = g.to_lower();
        if l == "hentai" || l == "adult" || l == "smut" { adult = true; }
        if l == "mature" || l == "ecchi" { mature = true; }
    }
    if adult { "adult" } else if mature { "suggestive" } else { "safe" }
}

// Turn a base36 MangaUpdates slug ("pb8uwds") into the numeric API id.
fn slug_to_id(slug) {
    let s = `${slug}`.trim().to_lower();
    let n = 0;
    for c in s.chars() {
        let v = if c >= '0' && c <= '9' { c.to_int() - 48 } else if c >= 'a' && c <= 'z' { c.to_int() - 87 } else { return s; };
        n = n * 36 + v;
    }
    `${n}`
}

fn record_to_series(record) {
    let series_id = `${record.series_id}`;
    let title = if record.title != () { record.title } else { "" };

    let cover_url = ();
    if record.image != () && record.image.url != () {
        let u = record.image.url;
        cover_url = if type_of(u) == "map" { if u.original != () { u.original } else { u.thumb } } else { u };
    }

    let genres = [];
    if record.genres != () {
        for g in record.genres { if g.genre != () { genres.push(g.genre); } }
    }

    let alt_titles = [];
    if record.associated != () {
        for a in record.associated {
            if a.title != () && a.title != title && !alt_titles.contains(a.title) { alt_titles.push(a.title); }
        }
    }

    let authors = [];
    let artists = [];
    if record.authors != () {
        for a in record.authors {
            if a.name == () { continue; }
            if a.type == "Artist" {
                if !artists.contains(a.name) { artists.push(a.name); }
            } else if !authors.contains(a.name) {
                authors.push(a.name);
            }
        }
    }

    // Only categories with a few votes, to keep single-user noise out.
    let tags = [];
    if record.categories != () {
        for c in record.categories {
            if c.category != () && (c.votes == () || c.votes >= 3) { tags.push(c.category); }
        }
    }

    let publishers = [];
    if record.publishers != () {
        for p in record.publishers {
            if p.publisher_name != () {
                publishers.push(#{ name: p.publisher_name, type: p.type });
            }
        }
    }

    let year = ();
    if record.year != () && record.year != "" { year = parse_int(`${record.year}`); }

    #{
        id: series_id,
        title: title,
        alternate_titles: alt_titles,
        description: record.description,
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: map_status(record.status, record.completed),
        genres: genres,
        tags: tags,
        year: year,
        content_rating: rating_from_genres(genres),
        chapter_count: record.latest_chapter,
        url: if record.url != () { record.url } else { `https://www.mangaupdates.com/series/${series_id}` },
        extra: #{
            provider: "mangaupdates",
            provider_id: series_id,
            mangaupdates_id: series_id,
            external_ids: #{ mangaupdates: series_id },
            format: record.type,
            score: record.bayesian_rating,
            rating_votes: record.rating_votes,
            latest_chapter: record.latest_chapter,
            licensed: record.licensed,
            completed: record.completed,
            status_raw: record.status,
            publishers: publishers,
            anime: record.anime,
            rank: record.rank
        }
    }
}

fn search_result(data, page) {
    if data == () || data.results == () {
        return #{ series: [], has_more: false, total: 0 };
    }
    let series = [];
    for item in data.results {
        if item.record != () { series.push(record_to_series(item.record)); }
    }
    let total = if data.total_hits != () { data.total_hits } else { 0 };
    #{ series: series, has_more: series.len() >= 25 && (page * 25) < total, total: total }
}

/// Search for series matching query (MangaUpdates search is a POST)
fn search_series(query, page, auth) {
    let p = page_or_one(page);
    search_result(mu_post("/series/search", #{ search: query, page: p, perpage: 25 }), p)
}

/// Get detailed series information by numeric id, base36 slug, or URL
fn get_series(id_or_url, auth) {
    let series_id = `${id_or_url}`;
    if series_id.contains("mangaupdates.com/series/") {
        series_id = series_id.split("/series/")[1].split("/")[0];
    }
    // Page URLs carry the base36 slug; the API wants the number.
    let numeric = true;
    for c in series_id.chars() { if c < '0' || c > '9' { numeric = false; break; } }
    if !numeric { series_id = slug_to_id(series_id); }

    let data = mu_get(`/series/${series_id}`);
    if data == () || data.series_id == () {
        return #{ id: series_id, title: "", error: "Series not found" };
    }
    record_to_series(data)
}

/// Get chapters - not applicable for metadata-only source
fn get_chapters(series_id, auth) {
    []
}

/// Get chapter pages - not applicable for metadata-only source
fn get_chapter_pages(chapter_id, auth) {
    []
}

/// Browse: series trending this week. (Was a literal search for "manga".)
fn get_latest_updates(page, auth) {
    let p = page_or_one(page);
    search_result(mu_post("/series/search", #{ orderby: "week_pos", page: p, perpage: 25 }), p)
}

/// Popular: highest rated series.
fn get_popular(page, auth) {
    let p = page_or_one(page);
    search_result(mu_post("/series/search", #{ orderby: "rating", page: p, perpage: 25 }), p)
}

fn browse(page, filters, auth) {
    get_popular(page, auth)
}

/// Get extended metadata for a series
fn get_metadata(series_id, auth) {
    get_series(series_id, auth)
}
