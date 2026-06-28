# =========================================================
# 3-class Trajectory Classification (Colab + Google Drive)
# - TRAIN: /content/drive/MyDrive/fenlei/train/<TRAIN_FILE>
# - TEST : /content/drive/MyDrive/fenlei/work/<TEST_FILE>
# - OUT  : /content/drive/MyDrive/fenlei/results/
# =========================================================

# ---------------------------
# 0) Install dependencies
# ---------------------------
!pip -q install pandas numpy openpyxl scipy scikit-learn matplotlib joblib
!pip -q install shap || true

import os
import time
import joblib
import random
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from dataclasses import dataclass
from typing import List, Dict, Any, Tuple, Optional

from scipy.spatial import ConvexHull
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score, f1_score, confusion_matrix, classification_report
from sklearn.ensemble import RandomForestClassifier

# ---------------------------
# 1) Google Drive mount
# ---------------------------
from google.colab import drive
drive.mount('/content/drive')

# =========================================================
# ============== CONFIGURATION BLOCK (EDIT HERE) ===========
# =========================================================
SEED = 42

BASE_DIR  = "/content/drive/MyDrive"
TRAIN_DIR = f"{BASE_DIR}/fenlei/train"
TEST_DIR  = f"{BASE_DIR}/fenlei/work"
OUT_DIR   = f"{BASE_DIR}/fenlei/results"

TRAIN_FILE = "train-build2.xlsx"        # Must use the 3-class training format: >=15 columns (3*5)
TEST_FILE  = "T+M-1-c7-SPINNResults.xlsx"

USE_TIMESTAMP = True

# If you know frame interval (seconds), set it; else None
FRAME_TIME = None  # e.g., 0.1

# ---------- MSD anomalous diffusion fitting ----------
FIT_TAU_MIN = 1
FIT_TAU_MAX = 8
MIN_TAU_POINTS_FOR_FIT = 3
MSD_STORE_FIRST_N = 5

# ---------- Test file column indices (0-based) ----------
TEST_COL_TRACK_ID = 0
TEST_COL_X        = 2
TEST_COL_Y        = 3
TEST_COL_DT       = 10

PRINT_TEST_PREVIEW = True
TEST_PREVIEW_ROWS = 8

# ---------- Model params ----------
RF_PARAMS = dict(
    n_estimators=600,
    random_state=SEED,
    class_weight="balanced",
    max_features="sqrt",
    n_jobs=-1
)

# ---------- NEW: number of classes ----------
N_CLASSES = 3
CLASS_LABELS = [1, 2, 3]
# =========================================================
# ================= END CONFIGURATION BLOCK ===============
# =========================================================

# ---------------------------
# 2) Reproducibility
# ---------------------------
random.seed(SEED)
np.random.seed(SEED)

# ---------------------------
# 3) Path utilities
# ---------------------------
def ensure_dir(path: str):
    os.makedirs(path, exist_ok=True)

def _has_ext(fname: str) -> bool:
    return os.path.splitext(fname)[1] != ""

def resolve_excel_path(directory: str, filename: str) -> str:
    candidates = []
    if _has_ext(filename):
        candidates.append(os.path.join(directory, filename))
    else:
        candidates.append(os.path.join(directory, filename + ".xlsx"))
        candidates.append(os.path.join(directory, filename + ".xls"))

    candidates_abs = [os.path.abspath(p) for p in candidates]
    for p in candidates_abs:
        if os.path.exists(p):
            return p

    msg = "File not found. Expected one of:\n" + "\n".join([f"  - {p}" for p in candidates_abs])
    raise FileNotFoundError(msg)

def stamp(name: str) -> str:
    if not USE_TIMESTAMP:
        return name
    t = time.strftime("%Y%m%d-%H%M%S")
    root, ext = os.path.splitext(name)
    return f"{root}_{t}{ext}"

# ---------------------------
# 4) Data structure
# ---------------------------
@dataclass
class Trajectory:
    label: Optional[int]
    track_id: Any
    x: np.ndarray
    y: np.ndarray
    dt: np.ndarray
    source: str = ""

# =========================================================
# 5) Training Excel parsing (3 blocks × 5 cols)
# =========================================================
def split_into_tracks(df_block: pd.DataFrame,
                      label_value: int,
                      allow_trackid_change_split: bool = True) -> List[Trajectory]:
    df = df_block[["track_id", "x", "y", "dt"]].copy()
    valid = df["x"].notna() & df["y"].notna()

    tracks: List[Trajectory] = []
    current_rows = []
    current_id = None

    for idx, row in df.iterrows():
        if not valid.loc[idx]:
            if len(current_rows) >= 2:
                seg = pd.DataFrame(current_rows)
                tracks.append(Trajectory(
                    label=label_value,
                    track_id=current_id,
                    x=seg["x"].to_numpy(dtype=float),
                    y=seg["y"].to_numpy(dtype=float),
                    dt=seg["dt"].to_numpy(dtype=float),
                    source=f"class{label_value}_block"
                ))
            current_rows = []
            current_id = None
            continue

        tid = row["track_id"]
        if current_id is None:
            current_id = tid

        if allow_trackid_change_split and (tid != current_id):
            if len(current_rows) >= 2:
                seg = pd.DataFrame(current_rows)
                tracks.append(Trajectory(
                    label=label_value,
                    track_id=current_id,
                    x=seg["x"].to_numpy(dtype=float),
                    y=seg["y"].to_numpy(dtype=float),
                    dt=seg["dt"].to_numpy(dtype=float),
                    source=f"class{label_value}_block"
                ))
            current_rows = []
            current_id = tid

        current_rows.append({"track_id": tid, "x": row["x"], "y": row["y"], "dt": row["dt"]})

    if len(current_rows) >= 2:
        seg = pd.DataFrame(current_rows)
        tracks.append(Trajectory(
            label=label_value,
            track_id=current_id,
            x=seg["x"].to_numpy(dtype=float),
            y=seg["y"].to_numpy(dtype=float),
            dt=seg["dt"].to_numpy(dtype=float),
            source=f"class{label_value}_block"
        ))

    return tracks


def load_training_excel(path: str, sheet_name: int | str = 0, n_classes: int = 3) -> List[Trajectory]:
    """
    Training excel: n_classes blocks * 5 columns
    Each block: label, track_id, x, y, dt
    """
    df = pd.read_excel(path, sheet_name=sheet_name, engine="openpyxl")
    if df.shape[1] < n_classes * 5:
        raise ValueError(
            f"Training file has {df.shape[1]} columns, expected >= {n_classes*5} "
            f"(for {n_classes} classes). Please make sure TRAIN_FILE is truly 3-class format."
        )

    trajectories: List[Trajectory] = []
    for c in range(n_classes):
        cols = df.columns[c*5:(c+1)*5]
        block = df.loc[:, cols].copy()
        block.columns = ["label", "track_id", "x", "y", "dt"]
        label_value = c + 1   # 1..3
        trajectories.extend(split_into_tracks(block, label_value=label_value))
    return trajectories

# =========================================================
# 6) New Excel loading (prediction)
# =========================================================
def load_new_excel(path: str,
                   sheet_name: int | str = 0,
                   track_id_col_index: int = 0,
                   x_col_index: int = 2,
                   y_col_index: int = 3,
                   dt_col_index: int = 10,
                   print_preview: bool = True) -> List[Trajectory]:
    df = pd.read_excel(path, sheet_name=sheet_name, engine="openpyxl")
    need = max(track_id_col_index, x_col_index, y_col_index, dt_col_index)
    if df.shape[1] <= need:
        raise ValueError(f"New file has {df.shape[1]} columns, but need at least index {need}.")

    if print_preview:
        print("\n[DEBUG] Test file preview (selected columns):")
        preview_cols = [track_id_col_index, x_col_index, y_col_index, dt_col_index]
        print(df.iloc[:TEST_PREVIEW_ROWS, preview_cols])
        nn = df.iloc[:, preview_cols].notna().sum()
        print("[DEBUG] non-null counts:", {f"col{c+1}": int(nn.iloc[i]) for i, c in enumerate(preview_cols)})

    tmp = pd.DataFrame({
        "track_id": df.iloc[:, track_id_col_index],
        "x": df.iloc[:, x_col_index],
        "y": df.iloc[:, y_col_index],
        "dt": df.iloc[:, dt_col_index]
    })

    tmp = tmp.dropna(subset=["track_id", "x", "y"])

    trajectories: List[Trajectory] = []
    for tid, g in tmp.groupby("track_id", sort=False):
        x = g["x"].to_numpy(dtype=float)
        y = g["y"].to_numpy(dtype=float)
        dt = g["dt"].to_numpy(dtype=float)
        if len(x) >= 2:
            trajectories.append(Trajectory(label=None, track_id=tid, x=x, y=y, dt=dt, source="new_file"))
    return trajectories

# =========================================================
# 7) Feature extraction (Anomalous diffusion)  [unchanged]
# =========================================================
def _quantiles(arr: np.ndarray, qs=(0.1, 0.25, 0.5, 0.75, 0.9)) -> Dict[str, float]:
    if arr is None or len(arr) == 0:
        return {f"q{int(q*100)}": np.nan for q in qs}
    return {f"q{int(q*100)}": float(np.nanquantile(arr, q)) for q in qs}

def msd_curve(x: np.ndarray, y: np.ndarray, max_tau: int) -> np.ndarray:
    n = len(x)
    max_tau = min(max_tau, n - 1)
    out = []
    for tau in range(1, max_tau + 1):
        dx = x[tau:] - x[:-tau]
        dy = y[tau:] - y[:-tau]
        out.append(np.nanmean(dx*dx + dy*dy))
    return np.array(out, dtype=float)

def fit_anomalous_msd(msd_vals: np.ndarray,
                      tau_min: int,
                      tau_max: int,
                      min_points: int = 3,
                      weights_mode: str = "pairs_like") -> Tuple[float, float]:
    k = len(msd_vals)
    if k < tau_min:
        return np.nan, np.nan

    tau_max_eff = min(tau_max, k)
    taus = np.arange(1, k+1, dtype=float)

    sel = (taus >= tau_min) & (taus <= tau_max_eff) & np.isfinite(msd_vals) & (msd_vals > 0)
    if sel.sum() < min_points:
        return np.nan, np.nan

    X = np.log(taus[sel])
    Y = np.log(msd_vals[sel])

    if weights_mode == "pairs_like":
        w = 1.0 / taus[sel]
    else:
        w = np.ones_like(X)

    alpha, intercept = np.polyfit(X, Y, 1, w=w)
    return float(alpha), float(intercept)

def compute_D_alpha_from_intercept(intercept: float, d: int = 2) -> float:
    if not np.isfinite(intercept):
        return np.nan
    return float(np.exp(intercept) / (2*d))

def compute_D_alpha_local(msd_vals: np.ndarray, alpha: float, taus: np.ndarray, d: int = 2) -> np.ndarray:
    if not np.isfinite(alpha):
        return np.full_like(msd_vals, np.nan, dtype=float)
    return msd_vals / ((2*d) * (taus**alpha) + 1e-12)

def extract_features(x: np.ndarray, y: np.ndarray, dt: Optional[np.ndarray], frame_time: Optional[float] = None) -> Dict[str, float]:
    feats: Dict[str, float] = {}

    x = np.asarray(x, dtype=float)
    y = np.asarray(y, dtype=float)
    n = len(x)
    feats["n_points"] = float(n)

    if n < 2:
        feats["alpha"] = np.nan
        feats["D_alpha_fit"] = np.nan
        feats["rg"] = np.nan
        feats["net_disp"] = np.nan
        feats["path_len"] = np.nan
        feats["tortuosity"] = np.nan
        return feats

    dx = np.diff(x)
    dy = np.diff(y)
    step = np.sqrt(dx*dx + dy*dy)
    feats["step_mean"] = float(np.nanmean(step))
    feats["step_std"] = float(np.nanstd(step))
    feats["step_median"] = float(np.nanmedian(step))
    feats["step_max"] = float(np.nanmax(step))
    feats.update({f"step_{k}": v for k, v in _quantiles(step, qs=(0.25,0.5,0.75,0.9)).items()})

    if frame_time is not None and frame_time > 0:
        vel = step / frame_time
        feats["vel_mean"] = float(np.nanmean(vel))
        feats["vel_std"] = float(np.nanstd(vel))
        feats["vel_max"] = float(np.nanmax(vel))
        feats.update({f"vel_{k}": v for k, v in _quantiles(vel, qs=(0.25,0.5,0.75,0.9)).items()})
    else:
        for k in ["vel_mean","vel_std","vel_max","vel_q25","vel_q50","vel_q75","vel_q90"]:
            feats[k] = np.nan

    max_tau = min(FIT_TAU_MAX, n-1)
    msd_vals = msd_curve(x, y, max_tau=max_tau)
    taus = np.arange(1, len(msd_vals)+1, dtype=float)

    for i in range(MSD_STORE_FIRST_N):
        feats[f"msd_tau{i+1}"] = float(msd_vals[i]) if i < len(msd_vals) else np.nan

    alpha, intercept = fit_anomalous_msd(
        msd_vals,
        tau_min=FIT_TAU_MIN,
        tau_max=FIT_TAU_MAX,
        min_points=MIN_TAU_POINTS_FOR_FIT,
        weights_mode="pairs_like"
    )
    feats["alpha"] = alpha
    feats["D_alpha_fit"] = compute_D_alpha_from_intercept(intercept, d=2)

    D_alpha_local = compute_D_alpha_local(msd_vals, alpha=alpha, taus=taus, d=2)
    feats["D_alpha_local_mean"] = float(np.nanmean(D_alpha_local)) if np.isfinite(D_alpha_local).any() else np.nan
    feats["D_alpha_local_std"]  = float(np.nanstd(D_alpha_local)) if np.isfinite(D_alpha_local).any() else np.nan
    feats.update({f"D_alpha_local_{k}": v for k, v in _quantiles(D_alpha_local, qs=(0.25,0.5,0.75,0.9)).items()})

    angles = np.arctan2(dy, dx)
    if len(angles) >= 2:
        dtheta = np.diff(angles)
        dtheta = (dtheta + np.pi) % (2*np.pi) - np.pi
        feats["turn_mean"] = float(np.nanmean(dtheta))
        feats["turn_std"] = float(np.nanstd(dtheta))
        feats.update({f"turn_{k}": v for k, v in _quantiles(dtheta, qs=(0.25,0.5,0.75,0.9)).items()})
        feats["dir_persistence_mean_cos"] = float(np.nanmean(np.cos(dtheta)))
    else:
        for k in ["turn_mean","turn_std","turn_q25","turn_q50","turn_q75","turn_q90","dir_persistence_mean_cos"]:
            feats[k] = np.nan

    x0 = x - np.nanmean(x)
    y0 = y - np.nanmean(y)
    rg2 = np.nanmean(x0*x0 + y0*y0)
    feats["rg"] = float(np.sqrt(rg2))

    net_disp = float(np.sqrt((x[-1]-x[0])**2 + (y[-1]-y[0])**2))
    path_len = float(np.nansum(step))
    feats["net_disp"] = net_disp
    feats["path_len"] = path_len
    feats["tortuosity"] = float(path_len / (net_disp + 1e-12))

    feats["x_range"] = float(np.nanmax(x) - np.nanmin(x))
    feats["y_range"] = float(np.nanmax(y) - np.nanmin(y))
    feats["bbox_area"] = float(feats["x_range"] * feats["y_range"])

    pts = np.vstack([x, y]).T
    pts = pts[np.all(np.isfinite(pts), axis=1)]
    if len(pts) >= 3:
        try:
            hull = ConvexHull(pts)
            feats["hull_area"] = float(hull.volume)
        except Exception:
            feats["hull_area"] = np.nan
    else:
        feats["hull_area"] = np.nan

    if len(pts) >= 3:
        cov = np.cov(pts.T)
        try:
            eig = np.linalg.eigvalsh(cov)
            eig = np.sort(eig)[::-1]
            feats["pca_var1"] = float(eig[0])
            feats["pca_var2"] = float(eig[1]) if len(eig) > 1 else np.nan
            feats["anisotropy_var_ratio"] = float((eig[0]+1e-12)/(eig[1]+1e-12)) if len(eig) > 1 else np.nan
        except Exception:
            feats["pca_var1"] = np.nan
            feats["pca_var2"] = np.nan
            feats["anisotropy_var_ratio"] = np.nan
    else:
        feats["pca_var1"] = np.nan
        feats["pca_var2"] = np.nan
        feats["anisotropy_var_ratio"] = np.nan

    if len(step) > 0:
        q25 = np.nanquantile(step, 0.25)
        q90 = np.nanquantile(step, 0.90)
        feats["large_step_frac_q90"] = float(np.nanmean(step > q90)) if np.isfinite(q90) else np.nan
        feats["small_step_frac_q25"] = float(np.nanmean(step < q25)) if np.isfinite(q25) else np.nan
        feats["n_large_steps_q90"] = float(np.nansum(step > q90)) if np.isfinite(q90) else np.nan
        feats["max_jump"] = float(np.nanmax(step))
    else:
        for k in ["large_step_frac_q90","small_step_frac_q25","n_large_steps_q90","max_jump"]:
            feats[k] = np.nan

    if dt is not None:
        dt = np.asarray(dt, dtype=float)
        dt = dt[np.isfinite(dt)]
        if len(dt) > 0:
            feats["dt_mean"] = float(np.nanmean(dt))
            feats["dt_std"] = float(np.nanstd(dt))
            feats["dt_min"] = float(np.nanmin(dt))
            feats["dt_max"] = float(np.nanmax(dt))
            feats.update({f"dt_{k}": v for k, v in _quantiles(dt, qs=(0.1,0.25,0.5,0.75,0.9)).items()})
            if len(dt) >= 2:
                ddt = np.diff(dt)
                feats["dt_diff_mean_abs"] = float(np.nanmean(np.abs(ddt)))
                feats["dt_diff_std"] = float(np.nanstd(ddt))
            else:
                feats["dt_diff_mean_abs"] = np.nan
                feats["dt_diff_std"] = np.nan
        else:
            for k in ["dt_mean","dt_std","dt_min","dt_max","dt_q10","dt_q25","dt_q50","dt_q75","dt_q90","dt_diff_mean_abs","dt_diff_std"]:
                feats[k] = np.nan
    else:
        for k in ["dt_mean","dt_std","dt_min","dt_max","dt_q10","dt_q25","dt_q50","dt_q75","dt_q90","dt_diff_mean_abs","dt_diff_std"]:
            feats[k] = np.nan

    if dt is not None and len(dt) >= 2 and len(step) >= 1:
        dt_step = dt[1:1+len(step)] if len(dt) > len(step) else dt[:len(step)]
        if len(dt_step) == len(step) and np.nanstd(dt_step) > 0 and np.nanstd(step) > 0:
            feats["corr_dt_step"] = float(np.corrcoef(dt_step, step)[0,1])
        else:
            feats["corr_dt_step"] = np.nan
    else:
        feats["corr_dt_step"] = np.nan

    return feats

# =========================================================
# 8) Build datasets + Train/Eval (3-class)
# =========================================================
def build_train_dataset(trajectories: List[Trajectory]) -> Tuple[pd.DataFrame, np.ndarray, List[str]]:
    rows, labels, tids = [], [], []
    for tr in trajectories:
        rows.append(extract_features(tr.x, tr.y, tr.dt, frame_time=FRAME_TIME))
        labels.append(tr.label)  # 1..3
        tids.append(tr.track_id)

    X = pd.DataFrame(rows)
    X.insert(0, "track_id", tids)
    y = np.array(labels, dtype=int)
    feature_names = [c for c in X.columns if c != "track_id"]
    return X, y, feature_names

def train_and_evaluate(X_df: pd.DataFrame, y: np.ndarray, feature_names: List[str], test_size=0.2):
    X_feat = X_df[feature_names].replace([np.inf, -np.inf], np.nan)

    # trajectory-level split
    X_train, X_val, y_train, y_val = train_test_split(
        X_feat, y, test_size=test_size, random_state=SEED, stratify=y
    )

    # impute by TRAIN medians only
    train_median = X_train.median(numeric_only=True)
    X_train_imp = X_train.fillna(train_median)
    X_val_imp   = X_val.fillna(train_median)

    model = RandomForestClassifier(**RF_PARAMS)
    model.fit(X_train_imp, y_train)

    y_pred = model.predict(X_val_imp)
    acc = accuracy_score(y_val, y_pred)
    macro_f1 = f1_score(y_val, y_pred, average="macro")

    cm = confusion_matrix(y_val, y_pred, labels=CLASS_LABELS)
    report = classification_report(y_val, y_pred, labels=CLASS_LABELS, output_dict=True, zero_division=0)

    # Confusion matrix fig
    fig = plt.figure(figsize=(5.2, 4.6))
    plt.imshow(cm, interpolation="nearest")
    plt.title("Confusion Matrix (Validation) - 3 classes")
    plt.xlabel("Predicted")
    plt.ylabel("True")
    plt.xticks(range(3), CLASS_LABELS)
    plt.yticks(range(3), CLASS_LABELS)
    for i in range(3):
        for j in range(3):
            plt.text(j, i, str(cm[i, j]), ha="center", va="center")
    plt.tight_layout()
    plt.close(fig)

    fi = pd.DataFrame({"feature": feature_names, "importance": model.feature_importances_}).sort_values("importance", ascending=False)

    metrics = {
        "accuracy": float(acc),
        "macro_f1": float(macro_f1),
        "confusion_matrix": cm.tolist(),
        "classification_report": report
    }
    artifacts = {"train_median": train_median, "confusion_fig": fig, "feature_importance_df": fi}
    return model, metrics, artifacts

# =========================================================
# 9) Feature alignment for prediction
# =========================================================
def build_feature_df_for_new(trajs_new: List[Trajectory],
                             feature_names: List[str],
                             train_median: pd.Series) -> pd.DataFrame:
    rows, tids = [], []
    for tr in trajs_new:
        rows.append(extract_features(tr.x, tr.y, tr.dt, frame_time=FRAME_TIME))
        tids.append(tr.track_id)

    X_new = pd.DataFrame(rows)
    X_new.insert(0, "track_id", tids)

    for col in feature_names:
        if col not in X_new.columns:
            X_new[col] = np.nan

    X_new = X_new[["track_id"] + feature_names].copy()
    X_new_feat = X_new[feature_names].replace([np.inf, -np.inf], np.nan).fillna(train_median)
    return pd.concat([X_new[["track_id"]], X_new_feat], axis=1)

# =========================================================
# 10) Explainability (SHAP compatible) + fallback
# =========================================================
def explain_predictions(model,
                        X_new_aligned: pd.DataFrame,
                        feature_names: List[str],
                        global_fi_df: pd.DataFrame,
                        train_center: pd.Series,
                        train_scale: pd.Series,
                        topn: int = 8) -> Tuple[pd.DataFrame, pd.DataFrame]:

    proba = model.predict_proba(X_new_aligned[feature_names])
    preds = model.predict(X_new_aligned[feature_names])
    classes_ = list(model.classes_)

    global_top20 = global_fi_df.head(20).copy()

    shap_ok = False
    shap_values_raw = None

    try:
        import shap
        explainer = shap.TreeExplainer(model)
        sv = explainer.shap_values(X_new_aligned[feature_names])
        shap_values_raw = sv.values if hasattr(sv, "values") else sv
        shap_ok = True
    except Exception:
        shap_ok = False
        shap_values_raw = None

    def get_shap_vector(shap_values, sample_i: int, class_i: int) -> Optional[np.ndarray]:
        if shap_values is None:
            return None
        if isinstance(shap_values, list):
            if class_i >= len(shap_values):
                return None
            arr = np.asarray(shap_values[class_i])
            if arr.ndim != 2 or sample_i >= arr.shape[0]:
                return None
            return arr[sample_i, :]
        arr = np.asarray(shap_values)
        if arr.ndim == 3:
            if sample_i >= arr.shape[0] or class_i >= arr.shape[2]:
                return None
            return arr[sample_i, :, class_i]
        if arr.ndim == 2:
            if sample_i >= arr.shape[0]:
                return None
            return arr[sample_i, :]
        return None

    # fallback weights
    imp_map = dict(zip(global_fi_df["feature"].values, global_fi_df["importance"].values))
    w = np.array([imp_map.get(fn, 0.0) for fn in feature_names], dtype=float)

    rows = []
    for i in range(len(X_new_aligned)):
        tid = X_new_aligned.iloc[i]["track_id"]
        pred = int(preds[i])
        p = proba[i]

        row = {"track_id": tid, "pred_label": pred}
        for ci, lab in enumerate(classes_):
            row[f"proba_class{int(lab)}"] = float(p[ci])

        top3 = np.argsort(p)[::-1][:min(3, len(p))]
        row["top3_labels"] = ",".join([str(int(classes_[j])) for j in top3])
        row["top3_probas"] = ",".join([f"{p[j]:.4f}" for j in top3])

        if shap_ok:
            class_idx = classes_.index(pred)
            sv_vec = get_shap_vector(shap_values_raw, sample_i=i, class_i=class_idx)
            if sv_vec is not None and len(sv_vec) == len(feature_names):
                idxs = np.argsort(np.abs(sv_vec))[::-1][:topn]
                for k, j in enumerate(idxs, start=1):
                    row[f"feat{k}"] = feature_names[j]
                    row[f"contrib{k}"] = float(sv_vec[j])
                row["explain_method"] = "SHAP(TreeExplainer)"
                rows.append(row)
                continue

        xrow = X_new_aligned.iloc[i][feature_names].to_numpy(dtype=float)
        z = (xrow - train_center.to_numpy(dtype=float)) / (train_scale.to_numpy(dtype=float) + 1e-12)
        contrib = z * w
        idxs = np.argsort(np.abs(contrib))[::-1][:topn]
        for k, j in enumerate(idxs, start=1):
            row[f"feat{k}"] = feature_names[j]
            row[f"contrib{k}"] = float(contrib[j])
        row["explain_method"] = "Fallback(z-score * global_importance)"
        rows.append(row)

    return pd.DataFrame(rows), global_top20

# =========================================================
# 11) Save outputs to Drive (3-class)
# =========================================================
def save_train_metrics(metrics: Dict[str, Any], out_path: str):
    report_df = pd.DataFrame(metrics["classification_report"]).T
    cm = np.array(metrics["confusion_matrix"], dtype=int)
    cm_df = pd.DataFrame(cm, index=[f"true_{i}" for i in CLASS_LABELS], columns=[f"pred_{i}" for i in CLASS_LABELS])
    summary_df = pd.DataFrame([{"accuracy": metrics["accuracy"], "macro_f1": metrics["macro_f1"]}])

    with pd.ExcelWriter(out_path, engine="openpyxl") as w:
        summary_df.to_excel(w, index=False, sheet_name="summary")
        report_df.to_excel(w, sheet_name="classification_report")
        cm_df.to_excel(w, sheet_name="confusion_matrix")

def save_df(df: pd.DataFrame, out_path: str):
    df.to_excel(out_path, index=False)

def save_confusion_fig(fig, out_path: str):
    fig.savefig(out_path, dpi=200)

# =========================================================
# 12) MAIN WORKFLOW
# =========================================================
ensure_dir(OUT_DIR)

train_path = resolve_excel_path(TRAIN_DIR, TRAIN_FILE)
test_path  = resolve_excel_path(TEST_DIR, TEST_FILE)

print("Resolved paths:")
print("  TRAIN_PATH =", train_path)
print("  TEST_PATH  =", test_path)
print("  OUT_DIR    =", os.path.abspath(OUT_DIR))

# --- Load training (3 classes) ---
train_trajs = load_training_excel(train_path, n_classes=N_CLASSES)
print("Parsed training trajectories:", len(train_trajs))
print("Class counts:", pd.Series([t.label for t in train_trajs]).value_counts().sort_index().to_dict())

# --- Build training dataset ---
X_df, y, feature_names = build_train_dataset(train_trajs)
print("Feature dimension:", len(feature_names))

# --- Train/evaluate ---
model, metrics, artifacts = train_and_evaluate(X_df, y, feature_names, test_size=0.2)
print("Validation Accuracy:", metrics["accuracy"])
print("Validation Macro-F1:", metrics["macro_f1"])

# Stats for fallback explanations
X_feat_full = X_df[feature_names].replace([np.inf, -np.inf], np.nan)
train_median = artifacts["train_median"]
X_full_imp = X_feat_full.fillna(train_median)
train_center = X_full_imp.mean()
train_scale  = X_full_imp.std(ddof=0).replace(0, 1.0)

# --- Load inference/test ---
test_trajs = load_new_excel(
    test_path,
    track_id_col_index=TEST_COL_TRACK_ID,
    x_col_index=TEST_COL_X,
    y_col_index=TEST_COL_Y,
    dt_col_index=TEST_COL_DT,
    print_preview=PRINT_TEST_PREVIEW
)
print("Parsed inference trajectories:", len(test_trajs))
if len(test_trajs) == 0:
    raise RuntimeError(
        "No valid trajectories parsed from test file. "
        "Please check TEST_COL_* indices in the CONFIG block and the preview output."
    )

# --- Build aligned features for test ---
X_new_aligned = build_feature_df_for_new(test_trajs, feature_names, train_median)

# --- Explain + predictions ---
explain_df, global_top20 = explain_predictions(
    model=model,
    X_new_aligned=X_new_aligned,
    feature_names=feature_names,
    global_fi_df=artifacts["feature_importance_df"],
    train_center=train_center,
    train_scale=train_scale,
    topn=8
)

# --- Export to Drive ---
pred_xlsx = os.path.join(OUT_DIR, stamp("predictions_explain_3class.xlsx"))
fi_xlsx   = os.path.join(OUT_DIR, stamp("feature_importance.xlsx"))
met_xlsx  = os.path.join(OUT_DIR, stamp("train_metrics_3class.xlsx"))
cm_png    = os.path.join(OUT_DIR, stamp("confusion_matrix_3class.png"))
model_pkl = os.path.join(OUT_DIR, stamp("model_3class.pkl"))

save_df(explain_df, pred_xlsx)
save_df(artifacts["feature_importance_df"], fi_xlsx)
save_train_metrics(metrics, met_xlsx)
save_confusion_fig(artifacts["confusion_fig"], cm_png)

bundle = {
    "model": model,
    "feature_names": feature_names,
    "train_median": train_median.to_dict(),
    "FRAME_TIME": FRAME_TIME,
    "FIT_TAU_MIN": FIT_TAU_MIN,
    "FIT_TAU_MAX": FIT_TAU_MAX,
    "MIN_TAU_POINTS_FOR_FIT": MIN_TAU_POINTS_FOR_FIT,
    "MSD_STORE_FIRST_N": MSD_STORE_FIRST_N,
    "TEST_COLS": dict(track_id=TEST_COL_TRACK_ID, x=TEST_COL_X, y=TEST_COL_Y, dt=TEST_COL_DT),
    "N_CLASSES": N_CLASSES
}
joblib.dump(bundle, model_pkl)

print("\nSaved outputs to OUT_DIR:")
print("  ", pred_xlsx)
print("  ", fi_xlsx)
print("  ", met_xlsx)
print("  ", cm_png)
print("  ", model_pkl)
