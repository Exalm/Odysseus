/**
* This file is part of Odysseus Web Browser (Copyright Adrian Cochrane 2017).
*
* Oddysseus is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Oddysseus is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.

* You should have received a copy of the GNU General Public License
* along with Oddysseus.  If not, see <http://www.gnu.org/licenses/>.
*/

/** Exposes our GLib.Resource templates to WebKit. */
namespace Oddysseus.Services {
    /* shortname for Templating.ByteUtils.from_string */
    private Bytes b(string s) {return Templating.ByteUtils.from_string(s);}

    private Templating.Data.Data parse_url_to_prosody(string url) {
        var raw = Templating.ByteUtils.create_map<Templating.Data.Data>();
        var raw_url = Templating.ByteUtils.create_map<Templating.Data.Data>();
        raw[b("url")] = new Templating.Data.Mapping(raw_url, url);

        var parser = new Soup.URI(url);
        raw_url[b("fragment")] = new Templating.Data.Literal(parser.fragment);
        raw_url[b("host")] = new Templating.Data.Literal(parser.host);
        raw_url[b("password")] = new Templating.Data.Literal(parser.password);
        raw_url[b("path")] = new Templating.Data.Literal(parser.path);
        raw_url[b("port")] = new Templating.Data.Literal(parser.port);
        // TODO parse this into a map
        // In doing so each key should be exposed as both a collection
        // and singular string.
        raw_url[b("query")] = new Templating.Data.Literal(parser.query);
        raw_url[b("scheme")] = new Templating.Data.Literal(parser.scheme);
        raw_url[b("user")] = new Templating.Data.Literal(parser.user);

        // Get the homepage
        var home = new Soup.URI.with_base(parser, "/");
        raw_url[b("home")] = new Templating.Data.Literal(home.to_string(false));

        return new Templating.Data.Mapping(raw);
    }

    private void render_error(WebKit.URISchemeRequest request, string error,
            Templating.Data.Data? base_data = null,
            Templating.TagBuilder? error_tag = null) {
        try {
            var path = "/" + Path.build_path("/",
                    "io", "github", "alcinnz", "Oddysseus", "oddysseus:", error);

            var raw_data =
                    Templating.ByteUtils.create_map<Templating.Data.Data>();
            raw_data[Templating.ByteUtils.from_string("url")] =
                    new Templating.Data.Literal(request.get_uri());
            raw_data[Templating.ByteUtils.from_string("path")] =
                    new Templating.Data.Literal(request.get_path());
            Templating.Data.Data data = new Templating.Data.Mapping(raw_data);
            if (base_data != null)
                data = new Templating.Data.Stack(data, base_data);

            Templating.ErrorData? error_data = null;
            Templating.Template template;
            if (error_tag == null)
                template = Templating.get_for_resource(path, ref error_data);
            else {
                // Parse specially with the custom {% error-line %} tag.
                var bytes = resources_lookup_data(path, 0);
                var parser = new Templating.Parser(bytes);
                var error_line_key =
                        Templating.ByteUtils.from_string("error-line");
                parser.local_tag_lib[error_line_key] = error_tag;
                template = parser.parse();
            }

            var stream = new Templating.InputStreamWriter();
            request.finish(stream, -1, "text/html");
            template.exec.begin(data, stream, (obj, res) => {
                stream.close_write();
            });
        } catch (Error err) {
            warning("Error reporting errors.");
            request.finish_error(err);
        }
    }

    public async void render_alternate_html(WebKit.WebView webview,
            string subpath, string? alt_uri = null, bool render_errors = true,
            Templating.Data.Data? data = null,
            Templating.TagBuilder? error_tag = null) {
        var alternative_uri = webview.uri;
        if (alt_uri != null) alternative_uri = alt_uri;

        var path = "/" + Path.build_path("/",
                "io", "github", "alcinnz", "Oddysseus", "oddysseus:", subpath);
        Templating.Template template;
        Templating.ErrorData? error_data = null;
        try {
            if (error_tag == null)
                template = Templating.get_for_resource(path, ref error_data);
            else {
                // Parse specially with custom {% error-line %} tag.
                var bytes = resources_lookup_data(path, 0);
                var parser = new Templating.Parser(bytes);
                var error_line_key =
                    Templating.ByteUtils.from_string("error-line");
                parser.local_tag_lib[error_line_key] = error_tag;
                template = parser.parse();
            }
        } catch (Templating.SyntaxError e) {
            if (render_errors)
                yield render_alternate_html(webview, "SERVER-ERROR",
                        alt_uri, false, error_data, error_data.tag);
            else webview.load_alternate_html(
                    @"<h1>$(e.domain)</h1><p>$(e.message)</p>",
                    alternative_uri, null);
            return;
        } catch (Error e) {
            if (render_errors) yield render_alternate_html(webview, "NOT-FOUND",
                    alt_uri, false);
            else webview.load_alternate_html(
                    @"<h1>$(e.domain)</h1><p>$(e.message)</p>",
                    alternative_uri, null);
            return;
        }

        Templating.Data.Data full_data;
        if (data != null)
            full_data = new Templating.Data.Stack(data,
                    parse_url_to_prosody(alternative_uri));
        else full_data = parse_url_to_prosody(alternative_uri);

        var stream = new Templating.CaptureWriter();
        yield template.exec(full_data, stream);
        var content = stream.grab_string();
        webview.load_alternate_html(content, alternative_uri, alternative_uri);
    }

    public void handle_oddysseus_uri(WebKit.URISchemeRequest request) {
        if (request.get_path().has_prefix("icon/")) {
            // Serve system icons for consistency there.
            // Done from the Oddysseus URI scheme so
            //      so they're allowed to be used as internal favicons
            handle_sysicon_uri(request);
            return;
        }

        var path = "/" + Path.build_path("/",
                "io", "github", "alcinnz", "Oddysseus", "oddysseus:",
                request.get_path());
        string? mime_type;
        try {
            mime_type = (string) resources_lookup_data(path + ".mime", 0)
                    .get_data();
        } catch (Error e) {
            mime_type = "+text/html";
        }

        if (mime_type[0] == '+') {
            mime_type = mime_type[1:mime_type.length];

            Templating.Template template;
            Templating.ErrorData? error_data = null;
            try {
                template = Templating.get_for_resource(path, ref error_data);
            } catch (Templating.SyntaxError e) {
                render_error(request, "SERVER-ERROR",
                        error_data, error_data.tag);
                return;
            } catch (Error e) {
                render_error(request, "NOT-FOUND");
                return;
            }
            Templating.Data.Data data = parse_url_to_prosody(request.get_uri());

            var stream = new Templating.InputStreamWriter();
            request.finish(stream, -1, mime_type);
            template.exec.begin(data, stream, (obj, res) => {
                stream.close_write();
            });
        } else {
            try {
                var stream = resources_open_stream(path, 0);
                request.finish(stream, -1, mime_type);
            } catch (Error e) {
                render_error(request, "NOT-FOUND");
                return;
            }
        }
    }
}
