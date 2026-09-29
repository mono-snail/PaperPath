# PaperPath website deployment

The `website/` directory is a dependency-free static site. Deploy its contents
as the web root.

Before production:

1. Replace the relative canonical, `hreflang`, Open Graph image, and JSON-LD
   image URLs in `index.html` and `en/index.html` with absolute URLs on the
   final domain.
2. Replace the "Coming soon" status in both pages with the public App Store
   URL after the listing is live.
3. Publish the finalized privacy policy and support contact, then link both
   from the footer.
4. Add a production `sitemap.xml` containing the Chinese and English absolute
   URLs, then add its absolute URL to `robots.txt`.

Local preview:

```bash
python3 -m http.server 4173 --directory website
```
