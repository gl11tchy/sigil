let meta = #{
    name: "ship-product-site",
    description: "Plan then build the sigilapp.dev product page, docs, and remote.sigilapp.dev origin split",
    when_to_use: "When shipping the public product site on sigilapp.dev and moving the phone relay to remote.sigilapp.dev",
    phases: [
        #{ title: "Plan", detail: "write spec and task list without touching the old phone-remote plan" },
        #{ title: "Origin", detail: "TDD the Mac default origin cutover" },
        #{ title: "Site", detail: "static product page and docs" },
        #{ title: "Verify", detail: "origin tests, site tests, then the repo verify script" },
    ],
};

fn require_ok(result, label) {
    if result == () || result.success != true {
        pause("verification", label);
    }
}

let plan_prompt = "";
plan_prompt += "You are in /Users/exec/Documents/sigil. Use read_file, grep, and write. Do not commit. ";
plan_prompt += "Do not edit tasks/plan.md or tasks/todo.md (those belong to unfinished phone-remote work). ";
plan_prompt += "Write three files only: tasks/product-site-spec.md, tasks/product-site-plan.md, tasks/product-site-todo.md. ";
plan_prompt += "Print this line at the top of the plan: Skills: using-agent-skills, spec-driven-development, planning-and-task-breakdown, test-driven-development, frontend-ui-engineering, impeccable, security-and-hardening, git-workflow-and-versioning. ";
plan_prompt += "ASSUMPTIONS: static Site/ on Railway for the apex; Sidereal stays a separate origin at https://remote.sigilapp.dev; GitHub Releases latest zip is the download; no accounts; no per-user subdomains; Namecheap DNS is owner-only. ";
plan_prompt += "Locked layout: sigilapp.dev = product page, sigilapp.dev/docs = docs, remote.sigilapp.dev = Sidereal PWA+relay. ";
plan_prompt += "Download URL: https://github.com/gl11tchy/sigil/releases/latest/download/Sigil.zip. Attribution handle gl11tchy only. ";
plan_prompt += "Spec must cover objective, commands, structure, style, testing, boundaries, success criteria. ";
plan_prompt += "Plan must be vertical slices with acceptance and verification. Tasks stay S/M. ";
plan_prompt += "Read PRODUCT.md, DESIGN.md, Sources/SigilApp/RemoteControl.swift, Sidereal/server.mjs, Scripts/verify.sh, and Tests/SigilAppTests/RemoteCommandsTests.swift before writing. ";
plan_prompt += "If you cannot read those files, fail instead of inventing paths.";

phase("Plan");
log("Writing product-site spec and tasks");
let plan_result = agent(plan_prompt, #{
    label: "plan",
    capability_mode: "read-write",
    agent_type: "general-purpose",
});
require_ok(plan_result, "Plan agent failed. Resume after the spec files exist.");

let origin_prompt = "";
origin_prompt += "You are in /Users/exec/Documents/sigil. Implement the origin cutover. Do not commit. Do not build the Site/ folder. ";
origin_prompt += "TDD first. Current code: Sources/SigilApp/RemoteControl.swift productionOrigin is https://sigilapp.dev and preferredOrigin only rewrites the old Railway URL. ";
origin_prompt += "RemoteControlView.swift onAppear already assigns preferredOrigin into AppStorage remoteServerURL. ";
origin_prompt += "RED: edit Tests/SigilAppTests/RemoteCommandsTests.swift qrIsDecodableAndURLValidationIsStrict so it fails until: ";
origin_prompt += "1) productionOrigin is exactly https://remote.sigilapp.dev ";
origin_prompt += "2) preferredOrigin(https://sidereal-production-587c.up.railway.app) returns productionOrigin ";
origin_prompt += "3) preferredOrigin(https://sigilapp.dev) returns productionOrigin ";
origin_prompt += "4) preferredOrigin(productionOrigin) is unchanged ";
origin_prompt += "5) preferredOrigin(https://example.com) is unchanged. ";
origin_prompt += "Run: swift test --no-parallel --filter RemoteCommandsTests.qrIsDecodableAndURLValidationIsStrict ";
origin_prompt += "Confirm RED, then GREEN in RemoteControl.swift: add a legacy apex constant, rewrite both legacy hosts in preferredOrigin, set productionOrigin to https://remote.sigilapp.dev. ";
origin_prompt += "Update every in-repo hosted-origin string for the relay (Sidereal/README.md, docs/remote-control.md, comments, tests) so the live companion is https://remote.sigilapp.dev. ";
origin_prompt += "Do not change Sidereal origin-check logic. PUBLIC_ORIGIN stays one exact origin. ";
origin_prompt += "Do not overwrite tasks/plan.md. Re-run the focused Swift test and stop when green.";

phase("Origin");
log("Cutting the Mac default origin over to remote.sigilapp.dev");
let origin_result = agent(origin_prompt, #{
    label: "origin",
    capability_mode: "all",
    agent_type: "general-purpose",
});
require_ok(origin_result, "Origin agent failed. Resume after productionOrigin is remote.sigilapp.dev and tests pass.");

let site_prompt = "";
site_prompt += "You are in /Users/exec/Documents/sigil. Build the public product site. Do not commit. Do not change Sidereal pairing crypto. ";
site_prompt += "Read PRODUCT.md, DESIGN.md, docs/screenshot.png, README.md, Sidereal/README.md, Sidereal/server.mjs, and tasks/product-site-spec.md if it exists. ";
site_prompt += "Create Site/ as a Node 22 static server modeled on Sidereal (tiny http server, Dockerfile, no websocket, no service worker). ";
site_prompt += "Files: Site/package.json, Site/server.mjs, Site/Dockerfile, Site/public/index.html, Site/public/docs/index.html, Site/public/style.css, Site/public/icon.svg, Site/test/site.test.mjs. ";
site_prompt += "Copy docs/screenshot.png to Site/public/screenshot.png. Add Site/node_modules/ to .gitignore. ";
site_prompt += "server.mjs: PUBLIC_ORIGIN must be an https origin (http only on localhost/127.0.0.1), same header set as Sidereal (CSP default-src self, script-src self, style-src self, img-src self, connect-src none, frame-ancestors none, nosniff, referrer no-referrer, HSTS on https), GET /health returns ok, GET / and /docs and /docs/ serve the pages, 404 otherwise, listen PORT or 3000. ";
site_prompt += "No third-party scripts, no analytics, no fonts from Google, no inline script, no inline style. CSS file only. ";
site_prompt += "Visual contract is DESIGN.md Sigil Neon, not a SaaS template: ground #08090B, text #D5DAE1, textDim #ABB0B8, accent #4EF0C4, hairline #2B2B2B, raised #1A1A1A, radius 6px. ";
site_prompt += "Type: system-ui / -apple-system / BlinkMacSystemFont for human copy; ui-monospace / SFMono-Regular / Menlo for paths and keycaps. Do not load Inter, Fraunces, Space Grotesk, or any Google font. ";
site_prompt += "Banned: purple gradients, gradient text, glassmorphism, 32px radii, identical feature-card grids, tiny uppercase tracked eyebrows on every section, numbered 01/02/03 markers as decoration, hero metrics. ";
site_prompt += "Landing / must include: the word Sigil, one-sentence product claim from PRODUCT.md, the screenshot with real alt text, a Download link to https://github.com/gl11tchy/sigil/releases/latest/download/Sigil.zip, install steps (unzip, replace /Applications/Sigil.app, macOS 14+), pair steps (Settings then Remote then scan; companion is https://remote.sigilapp.dev), a Docs link to /docs, a GitHub link to https://github.com/gl11tchy/sigil, attribution gl11tchy. ";
site_prompt += "Docs /docs: install, sidebar/search/tabs in plain language from README.md, remote pairing from Sidereal/README.md without leaking crypto details, self-host note that a phone cannot use localhost. ";
site_prompt += "Motion 150-200ms ease-out only for state, with prefers-reduced-motion. ";
site_prompt += "TDD: write Site/test/site.test.mjs with node:test first (start the server on a loopback port). It must fail, then pass. Cover /health, /, /docs, zip href, screenshot img, remote.sigilapp.dev mentioned, CSP present, no Content-Security-Policy unsafe-inline. ";
site_prompt += "Hook Site tests into Scripts/verify.sh immediately after Sidereal tests: npm --prefix Site ci --ignore-scripts && npm --prefix Site test. ";
site_prompt += "Do not add username subdomain routing. Do not put the landing page on the Sidereal origin. Run the Site tests until green.";

phase("Site");
log("Building the static product page and docs");
let site_result = agent(site_prompt, #{
    label: "site",
    capability_mode: "all",
    agent_type: "general-purpose",
});
require_ok(site_result, "Site agent failed. Resume after Site/ serves / and /docs with tests green.");

let verify_prompt = "";
verify_prompt += "You are in /Users/exec/Documents/sigil. Verify the product-site work. Do not commit. Do not add features. ";
verify_prompt += "Read the diff with git status and git diff. Confirm: ";
verify_prompt += "productionOrigin is https://remote.sigilapp.dev; preferredOrigin rewrites both https://sigilapp.dev and the old Railway host; ";
verify_prompt += "Site/ exists with tests; Scripts/verify.sh runs Site tests; tasks/plan.md was not overwritten. ";
verify_prompt += "Run: swift test --no-parallel --filter RemoteCommandsTests.qrIsDecodableAndURLValidationIsStrict ";
verify_prompt += "Then: npm --prefix Site test ";
verify_prompt += "If Site deps are missing, npm --prefix Site ci --ignore-scripts first. ";
verify_prompt += "If either command fails, fix only the regression, re-run that command, and do not expand scope. ";
verify_prompt += "Do not run the full Scripts/verify.sh unless those two already pass and you have time; prefer the focused commands. ";
verify_prompt += "Write a short report to tasks/product-site-verify.md: commands, exit codes, remaining owner DNS steps (Namecheap CNAME for remote.sigilapp.dev to the Railway target, then move the apex ALIAS onto the Site service). ";
verify_prompt += "Do not claim production is live. DNS is owner-only.";

phase("Verify");
log("Running origin and site tests");
let verify_result = agent(verify_prompt, #{
    label: "verify",
    capability_mode: "all",
    agent_type: "general-purpose",
});
require_ok(verify_result, "Verify agent failed. Resume after focused tests pass.");

let report = "Product site planned and built. Apex is the page; remote.sigilapp.dev is the relay. DNS is still owner-side.";
if verify_result.output != () {
    report = report + " Verify output recorded.";
}
let path = write_scratch_file("result.md", report);
complete(#{
    path: path,
    summary: report,
    origin: "https://remote.sigilapp.dev",
    site: "https://sigilapp.dev",
});
