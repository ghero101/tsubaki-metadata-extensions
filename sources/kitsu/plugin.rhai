// Kitsu Metadata Provider (Rhai)
// JSON:API based metadata provider for kitsu.io
// Provides manga metadata, ratings, and social features
//
// API Docs: https://kitsu.docs.apiary.io/
//
// Available APIs:
//   http_get(url) -> string
//   json_parse(text) -> Dynamic
//   url_encode(text) -> string

const API_BASE = "https://kitsu.io/api/edge";

/// Returns metadata about this source
fn get_source_info() {
    #{
        id: "kitsu-rhai",
        name: "Kitsu",
        base_url: API_BASE,
        language: "en",
        supported_languages: ["en", "ja"],
        requires_authentication: false,
        capability_level: "http_only",
        addon_type: "metadata"
    }
}

/// Get headers for Kitsu API
fn get_headers() {
    #{
        "Accept": "application/vnd.api+json",
        "Content-Type": "application/vnd.api+json"
    }
}


// ----------------------------------------------------------------------------
// Shared mapping. Every listing asks for the same includes and maps items
// through item_to_series(), so browse results carry the same ids (including
// MAL / AniList / MangaUpdates mappings) as get_series. The browse catalog
// stores list items as-is.
// ----------------------------------------------------------------------------

const LIST_INCLUDES = "categories,mappings";
const FULL_INCLUDES = "genres,categories,mappings,staff,staff.person";

fn kitsu_get(url) {
    let response = "";
    try { response = http_get_with_headers(url, get_headers()); } catch { return (); }
    if response == () || response == "" { return (); }
    let data = ();
    try { data = json_parse(response); } catch {}
    data
}

// "type:id" -> included resource
fn index_included(included) {
    let idx = #{};
    if included == () { return idx; }
    for inc in included { idx[`${inc.type}:${inc.id}`] = inc; }
    idx
}

// Resources linked from `item` under relationship `rel`.
fn related(item, rel, idx) {
    let out = [];
    if item.relationships == () { return out; }
    let r = item.relationships[rel];
    if r == () || r.data == () { return out; }
    let refs = if type_of(r.data) == "array" { r.data } else { [r.data] };
    for x in refs {
        let found = idx[`${x.type}:${x.id}`];
        if found != () { out.push(found); }
    }
    out
}

fn map_status(raw) {
    if raw == () { return (); }
    switch raw {
        "current" => "Ongoing",
        "finished" => "Completed",
        "tba" => "Upcoming",
        "unreleased" => "Upcoming",
        "upcoming" => "Upcoming",
        _ => raw
    }
}

// MangaUpdates mapping ids are base36 slugs ("pb8uwds"); the API id is the
// number they encode. All-digit values are the old legacy numbering.
// (Rhai passes maps by value, so this returns the updated map.)
fn mu_external(raw, ids) {
    let s = `${raw}`.trim().to_lower();
    if s == "" { return ids; }
    let n = 0;
    let digits = true;
    for c in s.chars() { if c < '0' || c > '9' { digits = false; } }
    if digits { ids.mangaupdates_legacy = s; return ids; }
    for c in s.chars() {
        let v = if c >= '0' && c <= '9' { c.to_int() - 48 } else if c >= 'a' && c <= 'z' { c.to_int() - 87 } else { return ids; };
        n = n * 36 + v;
    }
    ids.mangaupdates = `${n}`;
    ids
}

fn item_to_series(item, idx) {
    let id = `${item.id}`;
    let a = item.attributes;

    let titles = a.titles;
    let title = a.canonicalTitle;
    if (title == () || title == "") && titles != () {
        title = if titles.en != () { titles.en } else if titles.en_jp != () { titles.en_jp } else { titles.ja_jp };
    }
    if title == () { title = ""; }

    let alt_titles = [];
    if titles != () {
        for key in titles.keys() {
            let alt = titles[key];
            if alt != () && alt != "" && alt != title && !alt_titles.contains(alt) { alt_titles.push(alt); }
        }
    }
    if a.abbreviatedTitles != () {
        for alt in a.abbreviatedTitles {
            if alt != () && alt != "" && alt != title && !alt_titles.contains(alt) { alt_titles.push(alt); }
        }
    }

    let cover_url = ();
    if a.posterImage != () {
        let p = a.posterImage;
        cover_url = if p.original != () { p.original } else if p.large != () { p.large } else { p.medium };
    }
    let banner_url = ();
    if a.coverImage != () {
        banner_url = if a.coverImage.original != () { a.coverImage.original } else { a.coverImage.large };
    }

    let year = ();
    if a.startDate != () && a.startDate.len() >= 4 { year = parse_int(a.startDate.sub_string(0, 4)); }

    let genres = [];
    for g in related(item, "genres", idx) {
        if g.attributes != () && g.attributes.name != () && !genres.contains(g.attributes.name) { genres.push(g.attributes.name); }
    }
    let tags = [];
    for c in related(item, "categories", idx) {
        if c.attributes != () && c.attributes.title != () && !tags.contains(c.attributes.title) { tags.push(c.attributes.title); }
    }
    // Kitsu's genres relationship is mostly empty now; categories carry them.
    if genres.len() == 0 { genres = tags; tags = []; }

    let authors = [];
    let artists = [];
    for st in related(item, "staff", idx) {
        let role = if st.attributes != () && st.attributes.role != () { st.attributes.role.to_lower() } else { "" };
        let people = related(st, "person", idx);
        if people.len() == 0 || people[0].attributes == () { continue; }
        let name = people[0].attributes.name;
        if name == () || name == "" { continue; }
        if role.contains("story") || role.contains("author") || role.contains("writer") || role.contains("original") {
            if !authors.contains(name) { authors.push(name); }
        }
        if role.contains("art") || role.contains("illustrat") || role.contains("draw") {
            if !artists.contains(name) { artists.push(name); }
        }
    }

    let external_ids = #{ kitsu: id };
    for m in related(item, "mappings", idx) {
        let ma = m.attributes;
        if ma == () || ma.externalId == () { continue; }
        switch ma.externalSite {
            "myanimelist/manga" => { external_ids.mal = ma.externalId; }
            "anilist/manga" => { external_ids.anilist = ma.externalId; }
            "mangaupdates" => { external_ids = mu_external(ma.externalId, external_ids); }
            "mangadex" => { external_ids.mangadex = ma.externalId; }
            _ => {}
        }
    }

    let age = a.ageRating;
    let content_rating = if age == "R18" { "adult" } else if age == "R" { "mature" } else if age == "PG" || age == "PG-13" { "suggestive" } else { "safe" };

    #{
        id: id,
        title: title,
        alternate_titles: alt_titles,
        description: if a.synopsis != () { a.synopsis } else { a.description },
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: map_status(a.status),
        genres: genres,
        tags: tags,
        year: year,
        content_rating: content_rating,
        chapter_count: a.chapterCount,
        url: `https://kitsu.app/manga/${a.slug}`,
        extra: #{
            provider: "kitsu",
            provider_id: id,
            kitsu_id: id,
            slug: a.slug,
            external_ids: external_ids,
            format: a.subtype,
            score: a.averageRating,
            popularity_rank: a.popularityRank,
            rating_rank: a.ratingRank,
            user_count: a.userCount,
            volumes: a.volumeCount,
            chapters: a.chapterCount,
            start_date: a.startDate,
            end_date: a.endDate,
            serialization: a.serialization,
            age_rating: age,
            age_rating_guide: a.ageRatingGuide,
            banner_url: banner_url
        }
    }
}

fn list_result(data, offset) {
    if data == () || data.data == () {
        return #{ series: [], has_more: false, total: 0 };
    }
    let idx = index_included(data.included);
    let series = [];
    for item in data.data {
        if item.attributes == () { continue; }
        let s = item_to_series(item, idx);
        if s.title != "" { series.push(s); }
    }
    let total = if data.meta != () && data.meta.count != () { data.meta.count } else { () };
    let has_more = if total != () { offset + 20 < total } else { data.data.len() >= 20 };
    #{ series: series, has_more: has_more, total: total }
}

fn page_offset(page) {
    let p = if page == () || page < 1 { 1 } else { page };
    (p - 1) * 20
}

/// Search for series matching query
fn search_series(query, page, auth) {
    let offset = page_offset(page);
    list_result(kitsu_get(`${API_BASE}/manga?filter[text]=${url_encode(query)}&page[limit]=20&page[offset]=${offset}&include=${LIST_INCLUDES}`), offset)
}

/// Get detailed series information by id, slug, or kitsu URL
fn get_series(id_or_url, auth) {
    let key = `${id_or_url}`;
    if key.contains("/manga/") {
        key = key.split("/manga/")[1].split("/")[0].split("?")[0];
    }
    let numeric = key != "";
    for c in key.chars() { if c < '0' || c > '9' { numeric = false; break; } }

    let item = ();
    let data = ();
    if numeric {
        data = kitsu_get(`${API_BASE}/manga/${key}?include=${FULL_INCLUDES}`);
        if data != () { item = data.data; }
    } else {
        data = kitsu_get(`${API_BASE}/manga?filter[slug]=${url_encode(key)}&include=${FULL_INCLUDES}`);
        if data != () && data.data != () && data.data.len() > 0 { item = data.data[0]; }
    }
    if item == () || item.attributes == () {
        return #{ id: key, title: "", error: "Series not found" };
    }
    item_to_series(item, index_included(data.included))
}

/// Get chapters - not applicable for metadata-only source
fn get_chapters(series_id, auth) {
    []
}

/// Get chapter pages - not applicable for metadata-only source
fn get_chapter_pages(chapter_id, auth) {
    []
}

/// Browse: recently updated manga
fn get_latest_updates(page, auth) {
    let offset = page_offset(page);
    list_result(kitsu_get(`${API_BASE}/manga?sort=-updatedAt&page[limit]=20&page[offset]=${offset}&include=${LIST_INCLUDES}`), offset)
}

/// Popular: most followed manga
fn get_popular(page, auth) {
    let offset = page_offset(page);
    list_result(kitsu_get(`${API_BASE}/manga?sort=-userCount&page[limit]=20&page[offset]=${offset}&include=${LIST_INCLUDES}`), offset)
}
