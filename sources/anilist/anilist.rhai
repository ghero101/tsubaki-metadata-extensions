// AniList Metadata Provider
// Built-in addon for Tsubaki - provides manga metadata via AniList GraphQL API

const BASE_URL = "https://graphql.anilist.co";

// Get source information
fn get_source_info() {
    #{
        id: "anilist",
        name: "AniList",
        base_url: "https://anilist.co",
        language: "en",
        supported_languages: ["en", "ja"],
        requires_authentication: false,
        is_metadata_provider: true
    }
}

// Normalize string for comparison (lowercase, basic cleanup)
fn normalize(s) {
    // Simple normalization: lowercase and trim
    s.to_lower().trim()
}

// Wrap http_post_json so a network exception falls through to "" and
// downstream json_parse / data-access checks see "no data" rather than
// crashing the entire search / get_series / get_latest_updates call.
// All 7 GraphQL call sites in this plugin route through this helper.
fn safe_post(query) {
    try {
        return http_post_json(BASE_URL, query);
    } catch {
        return "";
    }
}

// Clean up AniList description. The API's `asHtml: false` strips most HTML
// but leaves <br> tags, markdown bold (__text__), and AniList's own spoiler
// syntax (~!hidden!~) in place. Pre-cleanup the UI rendered all of these
// verbatim, which looked broken.
fn clean_description(raw) {
    if raw == () || raw == "" { return raw; }
    let s = `${raw}`;
    // Newlines
    s = s.replace("<br>", "\n").replace("<br/>", "\n").replace("<br />", "\n");
    // Markdown bold/italic — keep the text, drop the markers
    s = s.replace("__", "").replace("**", "");
    // Common HTML entities AniList sometimes leaves in
    s = s.replace("&amp;", "&").replace("&nbsp;", " ").replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">");
    // AniList spoiler tags. Strip whole `~!...!~` regions — users can
    // toggle spoilers in the source UI; here they're noise.
    let cleaned = "";
    let i = 0;
    let in_spoiler = false;
    while i < s.len() {
        if !in_spoiler && i + 1 < s.len() && s.sub_string(i, 2) == "~!" {
            in_spoiler = true;
            i += 2;
        } else if in_spoiler && i + 1 < s.len() && s.sub_string(i, 2) == "!~" {
            in_spoiler = false;
            i += 2;
        } else {
            if !in_spoiler { cleaned += s.sub_string(i, 1); }
            i += 1;
        }
    }
    cleaned.trim()
}

// Map AniList status enum (RELEASING / FINISHED / HIATUS / CANCELLED /
// NOT_YET_RELEASED) to the canonical "Ongoing / Completed / Hiatus /
// Cancelled / Upcoming" set the UI filters on. Returns () for unknown values
// so callers can fall through.
fn normalize_status(raw) {
    if raw == () || raw == "" { return (); }
    let s = `${raw}`.to_upper();
    if s == "RELEASING" { return "Ongoing"; }
    if s == "FINISHED" { return "Completed"; }
    if s == "HIATUS" { return "Hiatus"; }
    if s == "CANCELLED" { return "Cancelled"; }
    if s == "NOT_YET_RELEASED" { return "Upcoming"; }
    raw
}

// ----------------------------------------------------------------------------
// Shared media mapping
//
// Every list endpoint (search / latest / popular / all) and get_series ask for
// the same field set and map it through media_to_series(), so a browse item
// carries the same ids, titles and metadata as a full get_series call. The
// browse catalog caches list items as-is, so anything left out of a list
// result is simply missing for catalog-added series.
// ----------------------------------------------------------------------------

fn media_fields() {
    "id idMal siteUrl title { romaji english native } synonyms description(asHtml: false) coverImage { extraLarge large medium } bannerImage genres tags { name rank isMediaSpoiler } status format countryOfOrigin volumes chapters isAdult averageScore meanScore popularity startDate { year month day } endDate { year month day } staff(perPage: 25) { edges { role node { name { full } } } } externalLinks { site url }"
}

// POST a GraphQL query with variables. The query text and variables are
// serialised with json_stringify, so user input (quotes, backslashes) can't
// break the request body.
fn gql(query, variables) {
    let body = json_stringify(#{ query: query, variables: variables });
    let response = safe_post(body);
    if response == () || response == "" { return (); }
    let json = ();
    try { json = json_parse(response); } catch { return (); }
    if json == () || json.data == () { return (); }
    json.data
}

fn pick_title(media) {
    let t = media.title;
    if t == () { return ""; }
    if t.english != () && t.english != "" { return t.english; }
    if t.romaji != () && t.romaji != "" { return t.romaji; }
    if t.native != () { return t.native; }
    ""
}

fn fuzzy_date(d) {
    if d == () || d.year == () { return (); }
    let s = `${d.year}`;
    if d.month != () {
        s += if d.month < 10 { `-0${d.month}` } else { `-${d.month}` };
        if d.day != () {
            s += if d.day < 10 { `-0${d.day}` } else { `-${d.day}` };
        }
    }
    s
}

fn media_to_series(media) {
    let title = pick_title(media);

    let alt_titles = [];
    let t = media.title;
    if t != () {
        for v in [t.romaji, t.english, t.native] {
            if v != () && v != "" && v != title && !alt_titles.contains(v) { alt_titles.push(v); }
        }
    }
    if media.synonyms != () {
        for v in media.synonyms {
            let s = `${v}`.trim();
            if s != "" && s != title && !alt_titles.contains(s) { alt_titles.push(s); }
        }
    }

    let cover_url = "";
    if media.coverImage != () {
        let c = media.coverImage;
        cover_url = if c.extraLarge != () { c.extraLarge } else if c.large != () { c.large } else if c.medium != () { c.medium } else { "" };
    }

    // Only tags with rank >= 60 and not spoilers, to keep noise out.
    let tags = [];
    if media.tags != () {
        for tag in media.tags {
            if tag.isMediaSpoiler == true { continue; }
            if tag.rank == () || tag.rank >= 60 { tags.push(tag.name); }
        }
    }

    let authors = [];
    let artists = [];
    let staff = [];
    if media.staff != () && media.staff.edges != () {
        for edge in media.staff.edges {
            if edge.node == () || edge.node.name == () || edge.node.name.full == () { continue; }
            let name = edge.node.name.full;
            let role = if edge.role != () { `${edge.role}` } else { "" };
            let r = role.to_lower();
            staff.push(#{ name: name, role: role });
            if (r.contains("story") || r.contains("original creator") || r.contains("writer")) && !authors.contains(name) {
                authors.push(name);
            }
            if (r.contains("art") || r.contains("illustration")) && !artists.contains(name) {
                artists.push(name);
            }
        }
    }

    let links = [];
    if media.externalLinks != () {
        for l in media.externalLinks {
            if l.url != () { links.push(#{ site: l.site, url: l.url }); }
        }
    }

    let external_ids = #{ anilist: media.id };
    if media.idMal != () { external_ids.mal = media.idMal; }

    let year = ();
    if media.startDate != () { year = media.startDate.year; }

    #{
        id: `${media.id}`,
        title: title,
        alternate_titles: alt_titles,
        description: clean_description(media.description),
        cover_url: cover_url,
        authors: authors,
        artists: artists,
        status: normalize_status(media.status),
        genres: if media.genres != () { media.genres } else { [] },
        tags: tags,
        year: year,
        content_rating: if media.isAdult == true { "adult" } else { "safe" },
        chapter_count: media.chapters,
        url: `https://anilist.co/manga/${media.id}`,
        extra: #{
            provider: "anilist",
            provider_id: `${media.id}`,
            anilist_id: media.id,
            mal_id: media.idMal,
            external_ids: external_ids,
            format: media.format,
            country: media.countryOfOrigin,
            score: media.averageScore,
            mean_score: media.meanScore,
            popularity: media.popularity,
            banner_url: media.bannerImage,
            volumes: media.volumes,
            chapters: media.chapters,
            start_date: fuzzy_date(media.startDate),
            end_date: fuzzy_date(media.endDate),
            staff: staff,
            links: links
        }
    }
}

// Run a paged Media query with an optional sort/search and map the results.
fn media_page(page, per_page, sort, search) {
    let args = "type: MANGA";
    let vars = #{ page: page, perPage: per_page };
    let decl = "$page: Int, $perPage: Int";
    if search != () && search != "" {
        args += ", search: $search";
        decl += ", $search: String";
        vars.search = search;
    }
    if sort != () && sort != "" {
        args += `, sort: ${sort}`;
    }
    let q = `query (${decl}) { Page(page: $page, perPage: $perPage) { pageInfo { total currentPage lastPage hasNextPage } media(${args}) { ${media_fields()} } } }`;
    let data = gql(q, vars);
    if data == () || data.Page == () {
        return #{ series: [], has_more: false, total: () };
    }
    let series = [];
    if data.Page.media != () {
        for media in data.Page.media { series.push(media_to_series(media)); }
    }
    let info = data.Page.pageInfo;
    #{
        series: series,
        has_more: if info != () && info.hasNextPage == true { true } else { false },
        total: if info != () { info.total } else { () },
        current_page: if info != () { info.currentPage } else { page }
    }
}

// Search for manga series. Pages are 1-indexed.
fn search_series(query, page, auth) {
    media_page(page_or_one(page), 20, "SEARCH_MATCH", query)
}

// Get detailed series information by ID or anilist.co URL
fn get_series(id_or_url, auth) {
    let id = `${id_or_url}`;
    if id.contains("anilist.co/manga/") {
        id = id.split("/manga/")[1].split("/")[0];
    }
    let n = parse_int(id);
    let data = gql(`query ($id: Int) { Media(id: $id, type: MANGA) { ${media_fields()} } }`, #{ id: n });
    if data == () || data.Media == () { return (); }
    media_to_series(data.Media)
}

// Host pages are 1-based for browse as well as search (browse_catalog.rs
// starts at page 1). The old `page + 1` here skipped the first page of every
// listing.
fn page_or_one(page) {
    if page == () || page < 1 { 1 } else { page }
}

// Trending manga (browse)
fn get_latest_updates(page, auth) {
    media_page(page_or_one(page), 25, "TRENDING_DESC", ())
}

// Most popular manga
fn get_popular(page, auth) {
    media_page(page_or_one(page), 25, "POPULARITY_DESC", ())
}

// Every manga sorted by ID, for a full catalogue sync (perPage max is 50)
fn get_all_manga(page, auth) {
    media_page(page_or_one(page), 50, "ID", ())
}

// Resolve manga title to AniList ID
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

    let target_norm = normalize(title);

    for q in candidates {
        let data = gql("query ($search: String) { Media(search: $search, type: MANGA) { id idMal title { romaji english native } synonyms } }", #{ search: q });
        if data == () || data.Media == () { continue; }
        let media = data.Media;
        // Accept a match on any of the entry's titles, not just the display
        // one: a source that names the series by its romaji title should still
        // resolve.
        let names = [media.title.english, media.title.romaji, media.title.native];
        if media.synonyms != () { names += media.synonyms; }
        let nq = normalize(q);
        for n in names {
            if n != () && n != "" && normalize(n) == nq {
                return #{
                    provider: "anilist",
                    provider_id: `${media.id}`,
                    matched_title: pick_title(media),
                    external_ids: if media.idMal != () { #{ anilist: media.id, mal: media.idMal } } else { #{ anilist: media.id } }
                };
            }
        }
    }

    ()
}

// ============================================================================
// TRACKING FEATURES - Requires OAuth2 Authentication
// Uses AniList GraphQL API: https://docs.anilist.co/guide/introduction
// ============================================================================

// Reading status mappings
// AniList statuses: CURRENT, PLANNING, COMPLETED, DROPPED, PAUSED, REPEATING
fn map_status_to_anilist(status) {
    switch status.to_lower() {
        "reading" | "current" => "CURRENT",
        "completed" | "finished" => "COMPLETED",
        "on_hold" | "paused" => "PAUSED",
        "dropped" => "DROPPED",
        "plan_to_read" | "planning" | "planned" => "PLANNING",
        "rereading" | "repeating" => "REPEATING",
        _ => "CURRENT"
    }
}

fn map_anilist_status(anilist_status) {
    switch anilist_status {
        "CURRENT" => "reading",
        "COMPLETED" => "completed",
        "PAUSED" => "on_hold",
        "DROPPED" => "dropped",
        "PLANNING" => "plan_to_read",
        "REPEATING" => "rereading",
        _ => "unknown"
    }
}

// Get authenticated user's info (needed for some queries)
fn get_viewer(auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    let query = `{
        "query": "query { Viewer { id name } }"
    }`;

    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`,
        "Content-Type": "application/json"
    };

    let response = http_post_json_with_headers(BASE_URL, query, headers);
    let json = json_parse(response);

    if json.errors != () {
        return #{ error: json.errors[0].message };
    }

    json.data.Viewer
}

// Get user's manga list
fn get_user_list(status_filter, page, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    let per_page = 50;
    let status_clause = "";
    if status_filter != () && status_filter != "" && status_filter != "all" {
        let al_status = map_status_to_anilist(status_filter);
        status_clause = `, status: ${al_status}`;
    }

    let query = `{
        "query": "query ($page: Int, $perPage: Int) { Page(page: $page, perPage: $perPage) { pageInfo { total currentPage lastPage hasNextPage } mediaList(type: MANGA, sort: UPDATED_TIME_DESC${status_clause}) { id mediaId status score progress progressVolumes repeat startedAt { year month day } completedAt { year month day } updatedAt notes priority private media { id title { romaji english native } coverImage { large } chapters volumes status } } } }",
        "variables": {"page": ${page}, "perPage": ${per_page}}
    }`;

    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`,
        "Content-Type": "application/json"
    };

    let response = http_post_json_with_headers(BASE_URL, query, headers);
    let json = json_parse(response);

    if json.errors != () {
        return #{ error: json.errors[0].message };
    }

    let entries = [];
    let page_info = json.data.Page.pageInfo;
    let list = json.data.Page.mediaList;

    if list != () {
        for item in list {
            let media = item.media;
            let title = "";
            if media.title.english != () && media.title.english != "" {
                title = media.title.english;
            } else if media.title.romaji != () {
                title = media.title.romaji;
            } else {
                title = media.title.native;
            }

            let start_date = ();
            if item.startedAt != () && item.startedAt.year != () {
                start_date = `${item.startedAt.year}-${item.startedAt.month}-${item.startedAt.day}`;
            }

            let finish_date = ();
            if item.completedAt != () && item.completedAt.year != () {
                finish_date = `${item.completedAt.year}-${item.completedAt.month}-${item.completedAt.day}`;
            }

            let entry_cover_url = "";
            if media.coverImage != () {
                entry_cover_url = media.coverImage.large;
            }

            entries.push(#{
                entry_id: `${item.id}`,
                manga_id: `${item.mediaId}`,
                title: title,
                cover_url: entry_cover_url,
                status: map_anilist_status(item.status),
                score: item.score,
                chapters_read: item.progress,
                volumes_read: item.progressVolumes,
                total_chapters: media.chapters,
                total_volumes: media.volumes,
                reread_count: item.repeat,
                start_date: start_date,
                finish_date: finish_date,
                updated_at: item.updatedAt,
                notes: item.notes,
                priority: item.priority,
                is_private: item["private"]
            });
        }
    }

    #{
        entries: entries,
        has_more: page_info.hasNextPage,
        total: page_info.total,
        current_page: page_info.currentPage
    }
}

// Get single manga entry from user's list
fn get_list_entry(manga_id, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    let query = `{
        "query": "query ($mediaId: Int) { MediaList(mediaId: $mediaId, type: MANGA) { id mediaId status score progress progressVolumes repeat startedAt { year month day } completedAt { year month day } updatedAt notes media { id title { romaji english } chapters volumes } } }",
        "variables": {"mediaId": ${manga_id}}
    }`;

    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`,
        "Content-Type": "application/json"
    };

    let response = http_post_json_with_headers(BASE_URL, query, headers);
    let json = json_parse(response);

    if json.errors != () {
        // Check if it's just not in list (expected error)
        if json.errors[0].message.contains("Not Found") || json.errors[0].status == 404 {
            return #{ not_in_list: true, manga_id: manga_id };
        }
        return #{ error: json.errors[0].message };
    }

    let item = json.data.MediaList;
    if item == () {
        return #{ not_in_list: true, manga_id: manga_id };
    }

    let media = item.media;
    let title = "";
    if media.title.english != () && media.title.english != "" {
        title = media.title.english;
    } else {
        title = media.title.romaji;
    }

    let entry_start_date = ();
    if item.startedAt != () && item.startedAt.year != () {
        entry_start_date = `${item.startedAt.year}-${item.startedAt.month}-${item.startedAt.day}`;
    }

    let entry_finish_date = ();
    if item.completedAt != () && item.completedAt.year != () {
        entry_finish_date = `${item.completedAt.year}-${item.completedAt.month}-${item.completedAt.day}`;
    }

    #{
        entry_id: `${item.id}`,
        manga_id: `${item.mediaId}`,
        title: title,
        status: map_anilist_status(item.status),
        score: item.score,
        chapters_read: item.progress,
        volumes_read: item.progressVolumes,
        total_chapters: media.chapters,
        total_volumes: media.volumes,
        reread_count: item.repeat,
        start_date: entry_start_date,
        finish_date: entry_finish_date,
        updated_at: item.updatedAt,
        notes: item.notes
    }
}

// Update manga entry in user's list (or add if not exists)
fn update_list_entry(manga_id, entry, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    // Build mutation variables
    let variables = `"mediaId": ${manga_id}`;

    if entry.status != () && entry.status != "" {
        let al_status = map_status_to_anilist(entry.status);
        variables = variables + `, "status": "${al_status}"`;
    }

    if entry.score != () {
        variables = variables + `, "score": ${entry.score}`;
    }

    if entry.chapters_read != () {
        variables = variables + `, "progress": ${entry.chapters_read}`;
    }

    if entry.volumes_read != () {
        variables = variables + `, "progressVolumes": ${entry.volumes_read}`;
    }

    if entry.reread_count != () {
        variables = variables + `, "repeat": ${entry.reread_count}`;
    }

    if entry.notes != () {
        variables = variables + `, "notes": "${entry.notes}"`;
    }

    // Use bracket notation for reserved keyword
    let is_private_val = entry["private"];
    if is_private_val != () {
        variables = variables + `, "private": ${is_private_val}`;
    }

    // Handle dates - AniList uses FuzzyDateInput { year, month, day }
    if entry.start_date != () && entry.start_date != "" {
        let parts = entry.start_date.split("-");
        if parts.len() >= 3 {
            variables = variables + `, "startedAt": { "year": ${parts[0]}, "month": ${parts[1]}, "day": ${parts[2]} }`;
        }
    }

    if entry.finish_date != () && entry.finish_date != "" {
        let parts = entry.finish_date.split("-");
        if parts.len() >= 3 {
            variables = variables + `, "completedAt": { "year": ${parts[0]}, "month": ${parts[1]}, "day": ${parts[2]} }`;
        }
    }

    let query = `{
        "query": "mutation ($mediaId: Int, $status: MediaListStatus, $score: Float, $progress: Int, $progressVolumes: Int, $repeat: Int, $notes: String, $private: Boolean, $startedAt: FuzzyDateInput, $completedAt: FuzzyDateInput) { SaveMediaListEntry(mediaId: $mediaId, status: $status, score: $score, progress: $progress, progressVolumes: $progressVolumes, repeat: $repeat, notes: $notes, private: $private, startedAt: $startedAt, completedAt: $completedAt) { id mediaId status score progress progressVolumes updatedAt } }",
        "variables": {${variables}}
    }`;

    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`,
        "Content-Type": "application/json"
    };

    let response = http_post_json_with_headers(BASE_URL, query, headers);
    let json = json_parse(response);

    if json.errors != () {
        return #{ success: false, error: json.errors[0].message };
    }

    let result = json.data.SaveMediaListEntry;

    #{
        success: true,
        entry_id: `${result.id}`,
        manga_id: `${result.mediaId}`,
        status: map_anilist_status(result.status),
        score: result.score,
        chapters_read: result.progress,
        volumes_read: result.progressVolumes,
        updated_at: result.updatedAt
    }
}

// Remove manga from user's list
fn remove_list_entry(manga_id, auth) {
    if auth.access_token == () || auth.access_token == "" {
        return #{ error: "Authentication required", requires_auth: true };
    }

    // First get the entry ID
    let current = get_list_entry(manga_id, auth);
    if current.not_in_list == true {
        return #{ success: true, manga_id: manga_id, message: "Entry not in list" };
    }
    if current.error != () {
        return #{ success: false, error: current.error };
    }

    let entry_id = current.entry_id;

    let query = `{
        "query": "mutation ($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }",
        "variables": {"id": ${entry_id}}
    }`;

    let headers = #{
        "Authorization": `Bearer ${auth.access_token}`,
        "Content-Type": "application/json"
    };

    let response = http_post_json_with_headers(BASE_URL, query, headers);
    let json = json_parse(response);

    if json.errors != () {
        return #{ success: false, error: json.errors[0].message };
    }

    #{
        success: json.data.DeleteMediaListEntry.deleted,
        manga_id: manga_id,
        entry_id: entry_id
    }
}

// Sync reading progress from local to AniList
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

// Get recommendations for a series from AniList
fn get_recommendations(manga_id, auth) {
    let query = `{
        "query": "query ($id: Int) { Media(id: $id, type: MANGA) { recommendations { nodes { rating mediaRecommendation { id title { romaji english } coverImage { large } } } } } }",
        "variables": {"id": ${manga_id}}
    }`;

    let response = safe_post(query);
    let json = json_parse(response);

    let recommendations = [];

    if json.data != () && json.data.Media != () && json.data.Media.recommendations != () {
        for node in json.data.Media.recommendations.nodes {
            if node.mediaRecommendation != () {
                let media = node.mediaRecommendation;
                let title = "";
                if media.title.english != () && media.title.english != "" {
                    title = media.title.english;
                } else {
                    title = media.title.romaji;
                }

                let rec_cover_url = "";
                if media.coverImage != () {
                    rec_cover_url = media.coverImage.large;
                }

                recommendations.push(#{
                    id: `${media.id}`,
                    title: title,
                    cover_url: rec_cover_url,
                    url: `https://anilist.co/manga/${media.id}`,
                    rating: node.rating
                });
            }
        }
    }

    #{
        recommendations: recommendations,
        total: recommendations.len()
    }
}


// Login function - validates client credentials are present
// AniList uses OAuth2 for user tracking, but client credentials enable authenticated API access
fn login(credentials) {
    let client_id = if credentials.anilist_client_id != () { credentials.anilist_client_id } else { "" };
    let client_secret = if credentials.anilist_client_secret != () { credentials.anilist_client_secret } else { "" };

    if client_id == "" {
        return #{
            success: false,
            error: "AniList Client ID is required. Get it from https://anilist.co/settings/developer"
        };
    }

    if client_secret == "" {
        return #{
            success: false,
            error: "AniList Client Secret is required. Get it from https://anilist.co/settings/developer"
        };
    }

    // Client credentials are valid - they will be used for OAuth2 authorization code flow
    // Return success so the credentials are stored for later OAuth use
    #{
        success: true,
        session_token: client_id,  // Store client_id as session marker
        message: "AniList credentials validated. Use OAuth to authorize user tracking."
    }
}
