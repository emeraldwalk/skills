#!/usr/bin/env python3
"""
embedder.py — Thin wrapper around sentence-transformers for local embeddings.

The model is lazy-loaded on first use and cached in memory by model name.
No API key or internet connection required after the first download.
"""

from typing import List

# Module-level cache: model_name -> SentenceTransformer instance
_model_cache: dict = {}


def embed_texts(
    texts: List[str],
    model_name: str = "all-MiniLM-L6-v2",
) -> List[List[float]]:
    """
    Embed a list of texts using sentence-transformers.

    Parameters
    ----------
    texts : list of str
        The texts to embed.  Empty strings are handled gracefully.
    model_name : str
        A sentence-transformers model name.  Defaults to all-MiniLM-L6-v2
        (384-dimensional, ~80 MB, fast CPU inference, good retrieval quality).

    Returns
    -------
    list of list of float
        One embedding vector per input text.  Each vector is a plain Python
        list of float values (not a numpy array) for easy JSON serialisation
        and struct packing.

    Raises
    ------
    ImportError
        If sentence-transformers is not installed.
    """
    model = _get_model(model_name)

    if not texts:
        return []

    # encode() returns a numpy ndarray of shape (n, dim)
    embeddings_np = model.encode(texts, show_progress_bar=False, convert_to_numpy=True)

    # Convert to plain Python lists so callers don't need numpy
    return [vec.tolist() for vec in embeddings_np]


def _get_model(model_name: str):
    """Return a cached SentenceTransformer, loading it on first call."""
    if model_name in _model_cache:
        return _model_cache[model_name]

    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print(
            "\nERROR: sentence-transformers is not installed.\n"
            "Install it with:\n"
            "    pip install sentence-transformers\n"
            "\nFor CPU-only environments (no CUDA):\n"
            "    pip install sentence-transformers torch --index-url https://download.pytorch.org/whl/cpu\n"
        )
        raise ImportError(
            "sentence-transformers is required for embedding generation. "
            "Run: pip install sentence-transformers"
        )

    model = SentenceTransformer(model_name)
    _model_cache[model_name] = model
    return model
