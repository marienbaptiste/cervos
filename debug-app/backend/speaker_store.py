"""
Cervos Voice Service — Speaker profile store (Chroma-backed)

Stores voice fingerprints (speaker embeddings) in a Chroma collection.
Each unique voice gets a persistent UUID that survives across sessions.
Names are assigned later (by user or LLM at summarization time).
"""

import uuid
import logging
from datetime import datetime, timezone

import numpy as np
import chromadb

logger = logging.getLogger("cervos-voice")

COLLECTION_NAME = "speaker_profiles"
SIMILARITY_THRESHOLD = 0.55  # cosine similarity — tuned for masked-audio embeddings from segmentation


class SpeakerStore:
    """
    Persistent speaker profile store backed by Chroma.

    - match_or_create(embedding) → speaker_id
    - Automatically refines centroid embeddings with each new sample
    - Names are optional and assigned separately
    """

    CONFIRM_COUNT = 3       # require N consistent non-matching embeddings before creating new speaker
    PENDING_SIMILARITY = 0.7  # pending embeddings must be this similar to each other

    def __init__(self, persist_dir: str = "/app/data/chroma", expected_dim: int = 192):
        logger.info(f"Initializing speaker store at {persist_dir}")
        self.similarity_threshold = SIMILARITY_THRESHOLD
        self.client = chromadb.PersistentClient(path=persist_dir)
        self.collection = self.client.get_or_create_collection(
            name=COLLECTION_NAME,
            metadata={"hnsw:space": "cosine"},
        )

        # Check if existing embeddings have wrong dimension (model change)
        if self.collection.count() > 0:
            sample = self.collection.peek(limit=1)
            if sample["embeddings"] is not None and len(sample["embeddings"]) > 0 and len(sample["embeddings"][0]) != expected_dim:
                old_dim = len(sample["embeddings"][0])
                logger.warning(f"Embedding dimension changed ({old_dim} → {expected_dim}), clearing speaker profiles")
                self.client.delete_collection(COLLECTION_NAME)
                self.collection = self.client.get_or_create_collection(
                    name=COLLECTION_NAME,
                    metadata={"hnsw:space": "cosine"},
                )

        # Pending buffer for new-speaker confirmation
        self._pending_embeddings = []  # list of embeddings that didn't match
        self._pending_count = 0

        count = self.collection.count()
        logger.info(f"Speaker store ready: {count} profiles (dim={expected_dim})")

    def match_or_create(self, embedding: np.ndarray) -> tuple[str, bool]:
        """
        Find the closest matching speaker or create a new profile.
        New speakers require CONFIRM_COUNT consistent non-matching embeddings.

        Returns (speaker_id, is_new).
        """
        embedding_list = embedding.tolist()

        # If collection is empty, first speaker — create immediately
        if self.collection.count() == 0:
            self._reset_pending()
            return self._create_profile(embedding_list), True

        # Query nearest neighbor
        results = self.collection.query(
            query_embeddings=[embedding_list],
            n_results=1,
            include=["metadatas", "distances", "embeddings"],
        )

        if not results["ids"][0]:
            self._reset_pending()
            return self._create_profile(embedding_list), True

        # Chroma cosine distance = 1 - cosine_similarity
        distance = results["distances"][0][0]
        similarity = 1.0 - distance
        existing_id = results["ids"][0][0]

        logger.info(f"Nearest speaker: {existing_id}, similarity: {similarity:.3f} (threshold: {self.similarity_threshold})")

        if similarity >= self.similarity_threshold:
            # Match found — update profile and reset pending
            self._update_profile(existing_id, embedding_list, results)
            self._reset_pending()
            return existing_id, False

        # No match — don't create immediately, buffer for confirmation
        if self._pending_count == 0:
            # First non-match: start pending buffer, return closest existing (tentative)
            self._pending_embeddings = [embedding]
            self._pending_count = 1
            logger.info(f"Pending new speaker (1/{self.CONFIRM_COUNT}), tentatively using {existing_id}")
            return existing_id, False

        # Check if this embedding is consistent with pending buffer
        pending_avg = np.mean(self._pending_embeddings, axis=0)
        pending_norm = np.linalg.norm(pending_avg)
        if pending_norm > 0:
            pending_avg = pending_avg / pending_norm
        pending_sim = np.dot(embedding, pending_avg)

        if pending_sim >= self.PENDING_SIMILARITY:
            # Consistent with pending — accumulate
            self._pending_embeddings.append(embedding)
            self._pending_count += 1
            logger.info(f"Pending new speaker ({self._pending_count}/{self.CONFIRM_COUNT}), "
                        f"pending_sim: {pending_sim:.3f}")

            if self._pending_count >= self.CONFIRM_COUNT:
                # Confirmed new speaker — create from average of pending embeddings
                avg_emb = np.mean(self._pending_embeddings, axis=0)
                avg_norm = np.linalg.norm(avg_emb)
                if avg_norm > 0:
                    avg_emb = avg_emb / avg_norm
                self._reset_pending()
                return self._create_profile(avg_emb.tolist()), True
            else:
                # Not yet confirmed, return closest existing
                return existing_id, False
        else:
            # Inconsistent with pending — reset buffer, start fresh
            logger.info(f"Pending reset (inconsistent: {pending_sim:.3f})")
            self._pending_embeddings = [embedding]
            self._pending_count = 1
            return existing_id, False

    def _reset_pending(self):
        self._pending_embeddings = []
        self._pending_count = 0

    def _create_profile(self, embedding_list: list[float]) -> str:
        """Create a new speaker profile with a unique ID."""
        speaker_id = f"spk_{uuid.uuid4().hex[:8]}"
        now = datetime.now(timezone.utc).isoformat()

        self.collection.add(
            ids=[speaker_id],
            embeddings=[embedding_list],
            metadatas=[{
                "name": "",
                "sample_count": 1,
                "first_seen": now,
                "last_seen": now,
            }],
        )
        logger.info(f"New speaker profile: {speaker_id}")
        return speaker_id

    def _update_profile(self, speaker_id: str, new_embedding: list[float],
                        query_results: dict) -> None:
        """Refine the centroid embedding with a new sample (running average)."""
        meta = query_results["metadatas"][0][0]
        old_embedding = query_results["embeddings"][0][0]
        sample_count = int(meta.get("sample_count", 1))

        # Running average: new_centroid = (old * n + new) / (n + 1)
        new_count = sample_count + 1
        centroid = [
            (old * sample_count + new) / new_count
            for old, new in zip(old_embedding, new_embedding)
        ]

        # Normalize to unit vector (cosine similarity expects this)
        norm = sum(x * x for x in centroid) ** 0.5
        if norm > 0:
            centroid = [x / norm for x in centroid]

        now = datetime.now(timezone.utc).isoformat()
        meta["sample_count"] = new_count
        meta["last_seen"] = now

        self.collection.update(
            ids=[speaker_id],
            embeddings=[centroid],
            metadatas=[meta],
        )

    def set_name(self, speaker_id: str, name: str) -> bool:
        """Assign a name to a speaker profile."""
        try:
            result = self.collection.get(ids=[speaker_id], include=["metadatas"])
            if not result["ids"]:
                return False
            meta = result["metadatas"][0]
            meta["name"] = name
            self.collection.update(ids=[speaker_id], metadatas=[meta])
            logger.info(f"Named speaker {speaker_id} → {name}")
            return True
        except Exception as e:
            logger.error(f"Failed to name speaker: {e}")
            return False

    def delete_profile(self, speaker_id: str) -> bool:
        """Delete a speaker profile."""
        try:
            self.collection.delete(ids=[speaker_id])
            logger.info(f"Deleted speaker {speaker_id}")
            return True
        except Exception:
            return False

    def get_all_profiles(self) -> list[dict]:
        """Return all speaker profiles (for UI and LLM context)."""
        if self.collection.count() == 0:
            return []

        results = self.collection.get(include=["metadatas"])
        profiles = []
        for id_, meta in zip(results["ids"], results["metadatas"]):
            profiles.append({
                "id": id_,
                "name": meta.get("name", "") or None,
                "sample_count": int(meta.get("sample_count", 0)),
                "first_seen": meta.get("first_seen"),
                "last_seen": meta.get("last_seen"),
            })
        return profiles

    def get_profile(self, speaker_id: str) -> dict | None:
        """Get a single speaker profile."""
        result = self.collection.get(ids=[speaker_id], include=["metadatas"])
        if not result["ids"]:
            return None
        meta = result["metadatas"][0]
        return {
            "id": speaker_id,
            "name": meta.get("name", "") or None,
            "sample_count": int(meta.get("sample_count", 0)),
            "first_seen": meta.get("first_seen"),
            "last_seen": meta.get("last_seen"),
        }
