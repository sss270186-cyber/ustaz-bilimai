
export default function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");

  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_PUBLISHABLE_KEY;

  if (!url || !key) {
    return res.status(503).json({
      error: "Supabase configuration missing"
    });
  }

  return res.status(200).json({
    url: url,
    publishableKey: key
  });
}
