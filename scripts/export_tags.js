// export_tags.js
// Run this snippet in your browser DevTools Console while logged into Project-GC
// at https://project-gc.com/Tools/Challenges?edit&scriptId=<scriptId>
//
// It queries the Project-GC web API for all tags specifically created for the specified script,
// sorts them numerically, and automatically triggers a download of tags_<scriptId>.json.

(async () => {
  const urlParams = new URLSearchParams(window.location.search);
  const scriptId = parseInt(urlParams.get("scriptId") || "9976", 10);
  const tagIds = [];
  let offset = 0;
  const limit = 100;
  console.log(`Fetching tags specifically for script ${scriptId}...`);

  while (true) {
    const res = await fetch(`/api/web/page/challenge-checkers/scripts/${scriptId}/tags?limit=${limit}&offset=${offset}`);
    if (!res.ok) {
      console.error("HTTP error:", res.status, res.statusText);
      break;
    }
    const json = await res.json();
    const data = json.data || [];
    if (data.length === 0) break;

    for (const tag of data) {
      if (tag.id) tagIds.push(tag.id);
    }

    console.log(`Fetched ${tagIds.length} tags...`);
    offset += limit;
    if (json.meta && offset >= json.meta.total) break;
  }

  tagIds.sort((a, b) => a - b);
  console.log(`Total tags for script ${scriptId}: ${tagIds.length}`);

  // Download directly as tags_9976.json
  const blob = new Blob([JSON.stringify(tagIds, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `tags_${scriptId}.json`;
  a.click();
  console.log(`Downloaded tags_${scriptId}.json!`);
})();
