CREATE INDEX relation_tuple_object_hist_idx
  ON relation_tuple (object_type, object_id, relation, id);

CREATE INDEX relation_tuple_subject_hist_idx
  ON relation_tuple
    (subject_type, subject_id, coalesce(subject_relation, ''), object_type, relation, id);
