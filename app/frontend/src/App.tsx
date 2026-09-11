import { useCallback, useEffect, useState, type FormEvent } from "react";
import { createIdea, fetchIdeas, getApiBaseUrl, type Idea } from "./api";

const MAX_LENGTH = 500;

function formatDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}

export default function App() {
  const [ideas, setIdeas] = useState<Idea[]>([]);
  const [content, setContent] = useState("");
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadIdeas = useCallback(async () => {
    setError(null);
    try {
      const data = await fetchIdeas();
      // Show newest ideas first regardless of backend ordering.
      setIdeas([...data].sort((a, b) => b.id - a.id));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load ideas");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadIdeas();
  }, [loadIdeas]);

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmed = content.trim();
    if (!trimmed || submitting) {
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      await createIdea(trimmed);
      setContent("");
      // Refresh the list so the new idea (and any concurrent ones) show up.
      await loadIdeas();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to submit idea");
    } finally {
      setSubmitting(false);
    }
  };

  const trimmedLength = content.trim().length;
  const canSubmit = trimmedLength > 0 && trimmedLength <= MAX_LENGTH && !submitting;

  return (
    <div className="app">
      <header className="app__header">
        <h1>💡 Idea Board</h1>
        <p className="app__subtitle">Share an idea. See what others are thinking.</p>
      </header>

      <main className="app__main">
        <form className="idea-form" onSubmit={handleSubmit}>
          <label className="idea-form__label" htmlFor="idea-input">
            Your idea
          </label>
          <textarea
            id="idea-input"
            className="idea-form__input"
            placeholder="What's your idea?"
            value={content}
            maxLength={MAX_LENGTH}
            rows={3}
            onChange={(e) => setContent(e.target.value)}
            disabled={submitting}
          />
          <div className="idea-form__footer">
            <span className="idea-form__count">
              {trimmedLength}/{MAX_LENGTH}
            </span>
            <button className="idea-form__submit" type="submit" disabled={!canSubmit}>
              {submitting ? "Submitting…" : "Submit idea"}
            </button>
          </div>
        </form>

        {error && (
          <div className="alert alert--error" role="alert">
            <span>{error}</span>
            <button type="button" className="alert__retry" onClick={() => void loadIdeas()}>
              Retry
            </button>
          </div>
        )}

        <section className="ideas" aria-live="polite">
          {loading ? (
            <p className="ideas__empty">Loading ideas…</p>
          ) : ideas.length === 0 ? (
            <p className="ideas__empty">No ideas yet. Be the first to add one!</p>
          ) : (
            <ul className="ideas__list">
              {ideas.map((idea) => (
                <li className="idea-card" key={idea.id}>
                  <p className="idea-card__content">{idea.content}</p>
                  <time className="idea-card__meta" dateTime={idea.created_at}>
                    {formatDate(idea.created_at)}
                  </time>
                </li>
              ))}
            </ul>
          )}
        </section>
      </main>

      <footer className="app__footer">
        <span>API: {getApiBaseUrl()}</span>
      </footer>
    </div>
  );
}
