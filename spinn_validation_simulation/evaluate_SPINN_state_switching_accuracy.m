function evaluate_SPINN_state_switching_accuracy_v2()
%% ============================================================
% Evaluate SPINN state-classification and state-switching accuracy
%
% 功能：
% 1. 弹窗选择 CSV 文件，第一行是标题行
% 2. 默认第 11 列为 SPINN-D
% 3. 默认第 12 列为 D_truth
% 4. 将 SPINN-D 和 D_truth 分别转换为 slow / fast 状态
% 5. 评估：
%    - 每一帧 slow/fast 状态分类准确性
%    - 真实 slow <-> fast 状态切换识别准确性
%    - 原始短轨迹拼接边界帧的状态准确性
%    - SPINN split 边界帧的状态准确性
%    - 人工拼接 transition 是否诱发假的状态切换
%
% 输入 CSV 要求：
%    第一行为标题行
%    第 11 列 = SPINN-D
%    第 12 列 = D_truth
%
% 输出：
%    <原文件名>_SPINN_state_accuracy_evaluation.xlsx
%    若干 PNG / FIG 图像
%
% 重要说明：
%    本代码不要求 SPINN-D 与 D_truth 数值逐帧相等，
%    而是评估 SPINN-D 是否能够正确区分 slow / fast 状态。
%% ============================================================

clear; clc;

%% =========================
% 1. 选择输入 CSV
%% =========================
[fileName, filePath] = uigetfile( ...
    {'*.csv', 'CSV files (*.csv)'}, ...
    '请选择包含 SPINN-D 和 D_truth 的 CSV 文件');

if isequal(fileName, 0)
    disp('已取消。');
    return;
end

infile = fullfile(filePath, fileName);

T = readtable(infile, 'VariableNamingRule', 'preserve');
nRows = height(T);
nCols = width(T);

if nRows < 2
    error('CSV 行数太少，无法分析。');
end

fprintf('Loaded file: %s\n', infile);
fprintf('Rows: %d\n', nRows);
fprintf('Columns: %d\n', nCols);

%% =========================
% 2. 参数输入
%% =========================
prompt = { ...
    'TrackID 所在列号；如果没有 TrackID，填 0：', ...
    'Frame 所在列号；如果没有 Frame，填 0：', ...
    'SPINN-D 所在列号：', ...
    'D_truth 所在列号：', ...
    '原始短轨迹长度，例如 20；如果不评估拼接边界，填 0：', ...
    'SPINN split 长度，例如 50；如果不评估 split 边界，填 0：', ...
    '边界额外窗口；0=只取边界两帧，1=取边界前后各1帧，2=前后各2帧：', ...
    ['SPINN-D 状态阈值方法：' newline ...
     '1 = log(SPINN-D) 两类聚类，推荐' newline ...
     '2 = 手动输入阈值' newline ...
     '3 = 自动寻找使准确率最高的阈值，作为上限参考' newline ...
     '4 = 使用 D_truth 的 slow/fast 阈值'], ...
    '如果方法=2，请输入手动 SPINN-D 阈值；否则留空：' ...
    };

dlgtitle = 'SPINN 状态切换准确性评估参数';
dims = [1 90];

defaultAns = { ...
    '1', ...      % TrackID column
    '2', ...      % Frame column
    '11', ...     % SPINN-D
    '12', ...     % D_truth
    '20', ...     % original short-track length
    '50', ...     % SPINN split length
    '1', ...      % boundary extra window
    '1', ...      % threshold method
    '' ...        % manual threshold
    };

answer = inputdlg(prompt, dlgtitle, dims, defaultAns);

if isempty(answer)
    disp('已取消。');
    return;
end

trackCol = str2double(answer{1});
frameCol = str2double(answer{2});
spinnDCol = str2double(answer{3});
truthDCol = str2double(answer{4});
shortTrackLen = str2double(answer{5});
splitLen = str2double(answer{6});
boundaryExtraWindow = str2double(answer{7});
thresholdMethod = str2double(answer{8});
manualThreshold = str2double(answer{9});

if isnan(trackCol), trackCol = 0; end
if isnan(frameCol), frameCol = 0; end
if isnan(spinnDCol), spinnDCol = 11; end
if isnan(truthDCol), truthDCol = 12; end
if isnan(shortTrackLen), shortTrackLen = 20; end
if isnan(splitLen), splitLen = 50; end
if isnan(boundaryExtraWindow), boundaryExtraWindow = 1; end
if isnan(thresholdMethod), thresholdMethod = 1; end

if spinnDCol < 1 || spinnDCol > nCols
    error('SPINN-D 列号超出表格范围。');
end

if truthDCol < 1 || truthDCol > nCols
    error('D_truth 列号超出表格范围。');
end

%% =========================
% 3. 读取 SPINN-D 和 D_truth
%% =========================
SPINN_D = convert_column_to_numeric(T{:, spinnDCol});
D_truth = convert_column_to_numeric(T{:, truthDCol});

validD = isfinite(SPINN_D) & isfinite(D_truth) & SPINN_D > 0 & D_truth > 0;

if sum(validD) < 10
    error('有效的 SPINN-D / D_truth 数据太少。请检查第 11 和第 12 列是否正确。');
end

%% =========================
% 4. 获取 TrackID 和 row-within-track
%% =========================
if trackCol >= 1 && trackCol <= nCols
    rawTrackID = T{:, trackCol};
    TrackGroupID = make_group_id(rawTrackID);
else
    TrackGroupID = ones(nRows, 1);
end

if frameCol >= 1 && frameCol <= nCols
    rawFrame = convert_column_to_numeric(T{:, frameCol});
else
    rawFrame = (1:nRows)';
end

rowWithinTrack = zeros(nRows, 1);
uniqueTracks = unique(TrackGroupID, 'stable');

for i = 1:numel(uniqueTracks)
    idx = find(TrackGroupID == uniqueTracks(i));
    rowWithinTrack(idx) = (1:numel(idx))';
end

%% =========================
% 5. 计算 truth state 和 predicted state
%% =========================
truthThreshold = estimate_two_state_threshold_log(D_truth(validD));

truthState = nan(nRows, 1);
truthState(validD & D_truth <= truthThreshold) = 1;  % slow
truthState(validD & D_truth >  truthThreshold) = 2;  % fast

switch thresholdMethod
    case 1
        spinnThreshold = estimate_two_state_threshold_log(SPINN_D(validD));
        thresholdMethodName = "kmeans_log_SPINN_D";

    case 2
        if isnan(manualThreshold) || manualThreshold <= 0
            error('你选择了手动阈值，但没有输入有效阈值。');
        end
        spinnThreshold = manualThreshold;
        thresholdMethodName = "manual";

    case 3
        spinnThreshold = find_best_threshold_for_accuracy(SPINN_D(validD), truthState(validD));
        thresholdMethodName = "best_accuracy_upper_bound";

    case 4
        spinnThreshold = truthThreshold;
        thresholdMethodName = "same_as_truth_threshold";

    otherwise
        spinnThreshold = estimate_two_state_threshold_log(SPINN_D(validD));
        thresholdMethodName = "kmeans_log_SPINN_D";
end

predState = nan(nRows, 1);
predState(validD & SPINN_D <= spinnThreshold) = 1;  % predicted slow
predState(validD & SPINN_D >  spinnThreshold) = 2;  % predicted fast

correctState = validD & predState == truthState;

TruthStateName = strings(nRows, 1);
TruthStateName(truthState == 1) = "slow";
TruthStateName(truthState == 2) = "fast";
TruthStateName(isnan(truthState)) = "invalid";

PredStateName = strings(nRows, 1);
PredStateName(predState == 1) = "slow";
PredStateName(predState == 2) = "fast";
PredStateName(isnan(predState)) = "invalid";

%% =========================
% 6. 标记拼接边界帧和 split 边界帧
%% =========================
IsConcatBoundaryFrame = false(nRows, 1);
IsSplitBoundaryFrame = false(nRows, 1);

% 原始短轨迹内部 local frame
% 如果 TrackID 是原始短轨迹 ID，则 rowWithinTrack = 1...20
% 如果 TrackID 是拼接后的 pseudo-track ID，则 rowWithinTrack 也可以按 shortTrackLen 取模。
if shortTrackLen > 0
    localShortFrame = mod(rowWithinTrack - 1, shortTrackLen) + 1;

    IsConcatBoundaryFrame = ...
        localShortFrame <= (1 + boundaryExtraWindow) | ...
        localShortFrame >= (shortTrackLen - boundaryExtraWindow);
else
    localShortFrame = nan(nRows, 1);
end

% SPINN split 边界应该按照全局行号判断，
% 因为 split 是对拼接后的长序列每 splitLen 帧切分一次。
if splitLen > 0
    globalRow = (1:nRows)';
    localSplitFrame = mod(globalRow - 1, splitLen) + 1;

    IsSplitBoundaryFrame = ...
        localSplitFrame <= (1 + boundaryExtraWindow) | ...
        localSplitFrame >= (splitLen - boundaryExtraWindow);
else
    localSplitFrame = nan(nRows, 1);
end

IsAnyBoundaryFrame = IsConcatBoundaryFrame | IsSplitBoundaryFrame;

%% =========================
% 7. 评估 frame-level 状态准确性
%% =========================
StateSummary = table();

StateSummary = [StateSummary; compute_state_metrics( ...
    "All valid frames", truthState, predState, validD)];

StateSummary = [StateSummary; compute_state_metrics( ...
    "Non-boundary frames", truthState, predState, validD & ~IsAnyBoundaryFrame)];

StateSummary = [StateSummary; compute_state_metrics( ...
    "Concat-boundary frames", truthState, predState, validD & IsConcatBoundaryFrame)];

StateSummary = [StateSummary; compute_state_metrics( ...
    "Split-boundary frames", truthState, predState, validD & IsSplitBoundaryFrame)];

StateSummary = [StateSummary; compute_state_metrics( ...
    "Any-boundary frames", truthState, predState, validD & IsAnyBoundaryFrame)];

%% =========================
% 8. 评估真实状态切换识别准确性
%% =========================
nTrans = nRows - 1;

% 相邻两行是否有效
validRowPair = ...
    validD(1:nTrans) & validD(2:nRows) & ...
    ~isnan(truthState(1:nTrans)) & ~isnan(truthState(2:nRows)) & ...
    ~isnan(predState(1:nTrans)) & ~isnan(predState(2:nRows));

% 相邻两行是否属于同一条原始轨迹
sameTrackTrans = TrackGroupID(1:nTrans) == TrackGroupID(2:nRows);

%% -------------------------
% 人工拼接 transition
% 重点：这里不要要求 sameTrackTrans
% 因为人工拼接点通常正好是 TrackID 变化处：
% Track 1 frame 20 -> Track 2 frame 1
%% -------------------------
if shortTrackLen > 0
    localShortFrame1 = localShortFrame(1:nTrans);
    localShortFrame2 = localShortFrame(2:nRows);

    IsArtificialConcatTransition = ...
        validRowPair & ...
        localShortFrame1 == shortTrackLen & ...
        localShortFrame2 == 1;
else
    IsArtificialConcatTransition = false(nTrans, 1);
end

%% -------------------------
% SPINN split transition
% 例如 splitLen = 50:
% localSplitFrame = 50 -> localSplitFrame = 1
%% -------------------------
if splitLen > 0
    localSplitFrame1 = localSplitFrame(1:nTrans);
    localSplitFrame2 = localSplitFrame(2:nRows);

    IsSplitTransition = ...
        validRowPair & ...
        localSplitFrame1 == splitLen & ...
        localSplitFrame2 == 1;
else
    IsSplitTransition = false(nTrans, 1);
end

%% -------------------------
% 真实状态切换与预测状态切换
%% -------------------------
truthSwitch = truthState(1:nTrans) ~= truthState(2:nRows);
predSwitch  = predState(1:nTrans)  ~= predState(2:nRows);

% 真实物理 transition：
% 只统计同一条原始轨迹内部的 transition
% 不把 Track 20 -> next Track 1 的人工拼接点当作真实状态切换
validRealTrans = validRowPair & sameTrackTrans;

%% -------------------------
% 边界附近 transition
%% -------------------------
IsBoundaryTransition = validRowPair & ...
    (IsAnyBoundaryFrame(1:nTrans) | IsAnyBoundaryFrame(2:nRows));

%% -------------------------
% 计算 switch-level accuracy
%% -------------------------
SwitchSummary = table();

SwitchSummary = [SwitchSummary; compute_switch_metrics( ...
    "All real within-track transitions", truthSwitch, predSwitch, validRealTrans)];

SwitchSummary = [SwitchSummary; compute_switch_metrics( ...
    "Non-boundary transitions", truthSwitch, predSwitch, validRealTrans & ~IsBoundaryTransition)];

SwitchSummary = [SwitchSummary; compute_switch_metrics( ...
    "Boundary-adjacent transitions", truthSwitch, predSwitch, validRealTrans & IsBoundaryTransition)];

SwitchSummary = [SwitchSummary; compute_switch_metrics( ...
    "Split-boundary transitions", truthSwitch, predSwitch, validRealTrans & IsSplitTransition)];

% 额外输出：人工拼接 transition 和 split transition 本身的 predicted switch rate
SwitchSummary = [SwitchSummary; compute_switch_metrics( ...
    "Artificial concat transitions only", truthSwitch, predSwitch, IsArtificialConcatTransition)];

SwitchSummary = [SwitchSummary; compute_switch_metrics( ...
    "All split transitions only", truthSwitch, predSwitch, IsSplitTransition)];

%% =========================
% 9. 真实切换帧附近的 frame-level 状态准确性
%% =========================
IsTrueSwitchAdjacentFrame = false(nRows, 1);

trueSwitchTransIndex = find(validRealTrans & truthSwitch);

for i = 1:numel(trueSwitchTransIndex)
    k = trueSwitchTransIndex(i);
    IsTrueSwitchAdjacentFrame(k) = true;
    IsTrueSwitchAdjacentFrame(k+1) = true;
end

StateSummary = [StateSummary; compute_state_metrics( ...
    "True-switch-adjacent frames", truthState, predState, validD & IsTrueSwitchAdjacentFrame)];

StateSummary = [StateSummary; compute_state_metrics( ...
    "Non-true-switch-adjacent frames", truthState, predState, validD & ~IsTrueSwitchAdjacentFrame)];

%% =========================
% 10. 专门评估人工拼接 transition 是否诱发假 switch
%% =========================
ArtificialConcatTransitionSummary = compute_artificial_concat_transition_summary( ...
    IsArtificialConcatTransition, predSwitch, truthState, predState, D_truth, SPINN_D);

SplitTransitionSummary = compute_split_transition_summary( ...
    IsSplitTransition, predSwitch, truthState, predState, D_truth, SPINN_D);

%% =========================
% 11. 将评估结果加入原始表格
%% =========================
T.Eval_RowIndex = (1:nRows)';
T.Eval_TrackGroupID = TrackGroupID;
T.Eval_RowWithinTrack = rowWithinTrack;
T.Eval_InputFrame = rawFrame;

T.Eval_SPINN_D = SPINN_D;
T.Eval_D_truth = D_truth;

T.Eval_TruthThreshold = repmat(truthThreshold, nRows, 1);
T.Eval_SPINNThreshold = repmat(spinnThreshold, nRows, 1);

T.Eval_TruthStateID = truthState;
T.Eval_TruthStateName = TruthStateName;
T.Eval_PredStateID = predState;
T.Eval_PredStateName = PredStateName;
T.Eval_CorrectState = correctState;

T.Eval_LocalShortFrame = localShortFrame;
T.Eval_IsConcatBoundaryFrame = IsConcatBoundaryFrame;

T.Eval_LocalSplitFrame = localSplitFrame;
T.Eval_IsSplitBoundaryFrame = IsSplitBoundaryFrame;

T.Eval_IsAnyBoundaryFrame = IsAnyBoundaryFrame;
T.Eval_IsTrueSwitchAdjacentFrame = IsTrueSwitchAdjacentFrame;

%% =========================
% 12. transition-level 输出表
%% =========================
TransitionTable = table( ...
    (1:nTrans)', ...
    TrackGroupID(1:nTrans), ...
    rowWithinTrack(1:nTrans), rowWithinTrack(2:nRows), ...
    truthState(1:nTrans), truthState(2:nRows), ...
    predState(1:nTrans), predState(2:nRows), ...
    truthSwitch, predSwitch, ...
    validRowPair, sameTrackTrans, validRealTrans, ...
    IsArtificialConcatTransition, IsSplitTransition, IsBoundaryTransition, ...
    'VariableNames', { ...
    'TransitionIndex', ...
    'TrackGroupID_start', ...
    'RowWithinTrack_start', 'RowWithinTrack_end', ...
    'TruthState_start', 'TruthState_end', ...
    'PredState_start', 'PredState_end', ...
    'TruthSwitch', 'PredSwitch', ...
    'ValidRowPair', 'SameTrackTransition', 'ValidRealTransition', ...
    'IsArtificialConcatTransition', 'IsSplitTransition', 'IsBoundaryTransition'} );

%% =========================
% 13. confusion matrices
%% =========================
Confusion_All = make_confusion_table(truthState, predState, validD);
Confusion_NonBoundary = make_confusion_table(truthState, predState, validD & ~IsAnyBoundaryFrame);
Confusion_AnyBoundary = make_confusion_table(truthState, predState, validD & IsAnyBoundaryFrame);
Confusion_ConcatBoundary = make_confusion_table(truthState, predState, validD & IsConcatBoundaryFrame);
Confusion_SplitBoundary = make_confusion_table(truthState, predState, validD & IsSplitBoundaryFrame);
Confusion_TrueSwitchAdjacent = make_confusion_table(truthState, predState, validD & IsTrueSwitchAdjacentFrame);

%% =========================
% 14. 输出 Excel
%% =========================
[~, baseName, ~] = fileparts(fileName);
outfile = fullfile(filePath, [baseName '_SPINN_state_accuracy_evaluation.xlsx']);

if exist(outfile, 'file')
    delete(outfile);
end

writetable(T, outfile, 'Sheet', 'PerFrameResults');
writetable(TransitionTable, outfile, 'Sheet', 'TransitionResults');
writetable(StateSummary, outfile, 'Sheet', 'StateAccuracySummary');
writetable(SwitchSummary, outfile, 'Sheet', 'SwitchAccuracySummary');
writetable(ArtificialConcatTransitionSummary, outfile, 'Sheet', 'ConcatBoundarySummary');
writetable(SplitTransitionSummary, outfile, 'Sheet', 'SplitBoundarySummary');

writetable(Confusion_All, outfile, 'Sheet', 'Confusion_All');
writetable(Confusion_NonBoundary, outfile, 'Sheet', 'Confusion_NonBoundary');
writetable(Confusion_AnyBoundary, outfile, 'Sheet', 'Confusion_AnyBoundary');
writetable(Confusion_ConcatBoundary, outfile, 'Sheet', 'Confusion_ConcatBoundary');
writetable(Confusion_SplitBoundary, outfile, 'Sheet', 'Confusion_SplitBoundary');
writetable(Confusion_TrueSwitchAdjacent, outfile, 'Sheet', 'Confusion_TrueSwitch');

SettingNames = { ...
    'InputFile';
    'nRows';
    'TrackIDColumn';
    'FrameColumn';
    'SPINN_D_Column';
    'D_truth_Column';
    'ShortTrackLength';
    'SPINNSplitLength';
    'BoundaryExtraWindow';
    'TruthThreshold';
    'SPINNThreshold';
    'ThresholdMethod';
    'ValidD_Rows';
    'NArtificialConcatTransitions';
    'NSplitTransitions'};

SettingValues = { ...
    infile;
    nRows;
    trackCol;
    frameCol;
    spinnDCol;
    truthDCol;
    shortTrackLen;
    splitLen;
    boundaryExtraWindow;
    truthThreshold;
    spinnThreshold;
    char(thresholdMethodName);
    sum(validD);
    sum(IsArtificialConcatTransition);
    sum(IsSplitTransition)};

SettingsTable = table(SettingNames, SettingValues);
writetable(SettingsTable, outfile, 'Sheet', 'Settings');

fprintf('\nDone.\n');
fprintf('Results saved to:\n%s\n', outfile);

%% =========================
% 15. 命令行显示关键结果
%% =========================
fprintf('\n========== Key results ==========\n');
fprintf('Truth threshold = %.6g\n', truthThreshold);
fprintf('SPINN threshold = %.6g\n', spinnThreshold);
fprintf('Threshold method = %s\n', thresholdMethodName);
fprintf('N artificial concat transitions = %d\n', sum(IsArtificialConcatTransition));
fprintf('N split transitions = %d\n', sum(IsSplitTransition));

disp('Frame-level state accuracy:');
disp(StateSummary);

disp('Transition-level switch accuracy:');
disp(SwitchSummary);

disp('Artificial concatenation transition summary:');
disp(ArtificialConcatTransitionSummary);

disp('Split transition summary:');
disp(SplitTransitionSummary);

%% =========================
% 16. 画图并安全保存
%% =========================
make_basic_plots(filePath, baseName, ...
    SPINN_D, D_truth, truthState, predState, ...
    validD, IsAnyBoundaryFrame, IsConcatBoundaryFrame, IsSplitBoundaryFrame, ...
    IsTrueSwitchAdjacentFrame, ...
    truthThreshold, spinnThreshold);

end

%% ============================================================
% Local function 1: convert table column to numeric
%% ============================================================
function x = convert_column_to_numeric(col)

if isnumeric(col)
    x = double(col);
elseif iscell(col)
    x = str2double(string(col));
elseif isstring(col)
    x = str2double(col);
elseif iscategorical(col)
    x = str2double(string(col));
elseif islogical(col)
    x = double(col);
else
    try
        x = double(col);
    catch
        x = str2double(string(col));
    end
end

x = x(:);

end

%% ============================================================
% Local function 2: make group ID from TrackID column
%% ============================================================
function groupID = make_group_id(rawID)

n = numel(rawID);

if isnumeric(rawID) || islogical(rawID)
    rawID = double(rawID(:));
    uniqueIDs = unique(rawID, 'stable');
    groupID = zeros(n, 1);

    for i = 1:numel(uniqueIDs)
        groupID(rawID == uniqueIDs(i)) = i;
    end
else
    rawStr = string(rawID(:));
    uniqueIDs = unique(rawStr, 'stable');
    groupID = zeros(n, 1);

    for i = 1:numel(uniqueIDs)
        groupID(rawStr == uniqueIDs(i)) = i;
    end
end

end

%% ============================================================
% Local function 3: estimate two-state threshold on log scale
%% ============================================================
function threshold = estimate_two_state_threshold_log(D)

D = D(:);
D = D(isfinite(D) & D > 0);

if isempty(D)
    threshold = NaN;
    return;
end

logD = log10(D);

if numel(unique(logD)) == 1
    threshold = 10 ^ logD(1);
    return;
end

% 自写 1D k-means，避免依赖 Statistics Toolbox
c1 = min(logD);
c2 = max(logD);

for iter = 1:100
    dist1 = abs(logD - c1);
    dist2 = abs(logD - c2);

    label = ones(size(logD));
    label(dist2 < dist1) = 2;

    if any(label == 1)
        newC1 = mean(logD(label == 1));
    else
        newC1 = c1;
    end

    if any(label == 2)
        newC2 = mean(logD(label == 2));
    else
        newC2 = c2;
    end

    if abs(newC1 - c1) < 1e-8 && abs(newC2 - c2) < 1e-8
        break;
    end

    c1 = newC1;
    c2 = newC2;
end

centers = sort([c1, c2]);
threshold = 10 ^ mean(centers);

end

%% ============================================================
% Local function 4: best threshold by accuracy
%% ============================================================
function bestThreshold = find_best_threshold_for_accuracy(D, truthState)

D = D(:);
truthState = truthState(:);

valid = isfinite(D) & D > 0 & ~isnan(truthState);

D = D(valid);
truthState = truthState(valid);

logD = log10(D);
sortedLogD = sort(unique(logD));

if numel(sortedLogD) < 2
    bestThreshold = 10 ^ sortedLogD(1);
    return;
end

candidateThresholds = (sortedLogD(1:end-1) + sortedLogD(2:end)) / 2;

bestAcc = -inf;
bestThrLog = candidateThresholds(1);

for i = 1:numel(candidateThresholds)
    thr = candidateThresholds(i);

    predState = ones(size(logD));
    predState(logD > thr) = 2;

    acc = mean(predState == truthState);

    if acc > bestAcc
        bestAcc = acc;
        bestThrLog = thr;
    end
end

bestThreshold = 10 ^ bestThrLog;

end

%% ============================================================
% Local function 5: state metrics
%% ============================================================
function Summary = compute_state_metrics(groupName, truthState, predState, mask)

mask = mask(:) & ~isnan(truthState(:)) & ~isnan(predState(:));

truth = truthState(mask);
pred = predState(mask);

n = numel(truth);

if n == 0
    Summary = table( ...
        groupName, 0, ...
        NaN, NaN, NaN, NaN, NaN, NaN, ...
        0, 0, 0, 0, ...
        'VariableNames', { ...
        'Group', 'NFrames', ...
        'Accuracy', 'BalancedAccuracy', ...
        'SlowRecall', 'FastRecall', ...
        'SlowPrecision', 'FastPrecision', ...
        'TrueSlow_PredSlow', 'TrueSlow_PredFast', ...
        'TrueFast_PredSlow', 'TrueFast_PredFast'} );
    return;
end

TS_PS = sum(truth == 1 & pred == 1);
TS_PF = sum(truth == 1 & pred == 2);
TF_PS = sum(truth == 2 & pred == 1);
TF_PF = sum(truth == 2 & pred == 2);

accuracy = (TS_PS + TF_PF) / n;

slowRecall = safe_div(TS_PS, TS_PS + TS_PF);
fastRecall = safe_div(TF_PF, TF_PS + TF_PF);

slowPrecision = safe_div(TS_PS, TS_PS + TF_PS);
fastPrecision = safe_div(TF_PF, TS_PF + TF_PF);

balancedAccuracy = mean([slowRecall, fastRecall], 'omitnan');

Summary = table( ...
    groupName, n, ...
    accuracy, balancedAccuracy, ...
    slowRecall, fastRecall, ...
    slowPrecision, fastPrecision, ...
    TS_PS, TS_PF, TF_PS, TF_PF, ...
    'VariableNames', { ...
    'Group', 'NFrames', ...
    'Accuracy', 'BalancedAccuracy', ...
    'SlowRecall', 'FastRecall', ...
    'SlowPrecision', 'FastPrecision', ...
    'TrueSlow_PredSlow', 'TrueSlow_PredFast', ...
    'TrueFast_PredSlow', 'TrueFast_PredFast'} );

end

%% ============================================================
% Local function 6: switch metrics
%% ============================================================
function Summary = compute_switch_metrics(groupName, truthSwitch, predSwitch, mask)

mask = mask(:);

truth = truthSwitch(mask);
pred = predSwitch(mask);

n = numel(truth);

if n == 0
    Summary = table( ...
        groupName, 0, ...
        NaN, NaN, NaN, NaN, NaN, ...
        0, 0, 0, 0, ...
        'VariableNames', { ...
        'Group', 'NTransitions', ...
        'Accuracy', 'Precision', 'Recall', 'F1', 'FalsePositiveRate', ...
        'TP', 'FP', 'FN', 'TN'} );
    return;
end

TP = sum(truth == true  & pred == true);
FP = sum(truth == false & pred == true);
FN = sum(truth == true  & pred == false);
TN = sum(truth == false & pred == false);

accuracy = (TP + TN) / n;
precision = safe_div(TP, TP + FP);
recall = safe_div(TP, TP + FN);
F1 = safe_div(2 * precision * recall, precision + recall);
falsePositiveRate = safe_div(FP, FP + TN);

Summary = table( ...
    groupName, n, ...
    accuracy, precision, recall, F1, falsePositiveRate, ...
    TP, FP, FN, TN, ...
    'VariableNames', { ...
    'Group', 'NTransitions', ...
    'Accuracy', 'Precision', 'Recall', 'F1', 'FalsePositiveRate', ...
    'TP', 'FP', 'FN', 'TN'} );

end

%% ============================================================
% Local function 7: artificial concatenation transition summary
%% ============================================================
function Summary = compute_artificial_concat_transition_summary( ...
    IsArtificialConcatTransition, predSwitch, truthState, predState, D_truth, SPINN_D)

mask = IsArtificialConcatTransition(:);

n = sum(mask);

if n == 0
    Summary = table( ...
        0, NaN, NaN, NaN, NaN, NaN, ...
        'VariableNames', { ...
        'NArtificialConcatTransitions', ...
        'PredictedSwitchRateAtConcat', ...
        'TruthStateDifferentAcrossConcatRate', ...
        'PredStateDifferentAcrossConcatRate', ...
        'MeanAbsTruthDJumpAcrossConcat', ...
        'MeanAbsSPINNDJumpAcrossConcat'} );
    return;
end

idx = find(mask);

predSwitchRate = mean(predSwitch(mask));

truthStateDiff = truthState(idx) ~= truthState(idx + 1);
predStateDiff = predState(idx) ~= predState(idx + 1);

truthStateDiffRate = mean(truthStateDiff, 'omitnan');
predStateDiffRate = mean(predStateDiff, 'omitnan');

truthDJump = abs(D_truth(idx + 1) - D_truth(idx));
spinnDJump = abs(SPINN_D(idx + 1) - SPINN_D(idx));

meanTruthDJump = mean(truthDJump, 'omitnan');
meanSPINNDJump = mean(spinnDJump, 'omitnan');

Summary = table( ...
    n, predSwitchRate, truthStateDiffRate, predStateDiffRate, meanTruthDJump, meanSPINNDJump, ...
    'VariableNames', { ...
    'NArtificialConcatTransitions', ...
    'PredictedSwitchRateAtConcat', ...
    'TruthStateDifferentAcrossConcatRate', ...
    'PredStateDifferentAcrossConcatRate', ...
    'MeanAbsTruthDJumpAcrossConcat', ...
    'MeanAbsSPINNDJumpAcrossConcat'} );

end

%% ============================================================
% Local function 8: split transition summary
%% ============================================================
function Summary = compute_split_transition_summary( ...
    IsSplitTransition, predSwitch, truthState, predState, D_truth, SPINN_D)

mask = IsSplitTransition(:);

n = sum(mask);

if n == 0
    Summary = table( ...
        0, NaN, NaN, NaN, NaN, NaN, ...
        'VariableNames', { ...
        'NSplitTransitions', ...
        'PredictedSwitchRateAtSplit', ...
        'TruthStateDifferentAcrossSplitRate', ...
        'PredStateDifferentAcrossSplitRate', ...
        'MeanAbsTruthDJumpAcrossSplit', ...
        'MeanAbsSPINNDJumpAcrossSplit'} );
    return;
end

idx = find(mask);

predSwitchRate = mean(predSwitch(mask));

truthStateDiff = truthState(idx) ~= truthState(idx + 1);
predStateDiff = predState(idx) ~= predState(idx + 1);

truthStateDiffRate = mean(truthStateDiff, 'omitnan');
predStateDiffRate = mean(predStateDiff, 'omitnan');

truthDJump = abs(D_truth(idx + 1) - D_truth(idx));
spinnDJump = abs(SPINN_D(idx + 1) - SPINN_D(idx));

meanTruthDJump = mean(truthDJump, 'omitnan');
meanSPINNDJump = mean(spinnDJump, 'omitnan');

Summary = table( ...
    n, predSwitchRate, truthStateDiffRate, predStateDiffRate, meanTruthDJump, meanSPINNDJump, ...
    'VariableNames', { ...
    'NSplitTransitions', ...
    'PredictedSwitchRateAtSplit', ...
    'TruthStateDifferentAcrossSplitRate', ...
    'PredStateDifferentAcrossSplitRate', ...
    'MeanAbsTruthDJumpAcrossSplit', ...
    'MeanAbsSPINNDJumpAcrossSplit'} );

end

%% ============================================================
% Local function 9: confusion table
%% ============================================================
function ConfusionTable = make_confusion_table(truthState, predState, mask)

mask = mask(:) & ~isnan(truthState(:)) & ~isnan(predState(:));

truth = truthState(mask);
pred = predState(mask);

TS_PS = sum(truth == 1 & pred == 1);
TS_PF = sum(truth == 1 & pred == 2);
TF_PS = sum(truth == 2 & pred == 1);
TF_PF = sum(truth == 2 & pred == 2);

TruthClass = ["Truth_slow"; "Truth_fast"];
Pred_slow = [TS_PS; TF_PS];
Pred_fast = [TS_PF; TF_PF];

ConfusionTable = table(TruthClass, Pred_slow, Pred_fast);

end

%% ============================================================
% Local function 10: safe division
%% ============================================================
function y = safe_div(a, b)

if b == 0
    y = NaN;
else
    y = a / b;
end

end

%% ============================================================
% Local function 11: make plots
%% ============================================================
function make_basic_plots(filePath, baseName, ...
    SPINN_D, D_truth, truthState, predState, ...
    validD, IsAnyBoundaryFrame, IsConcatBoundaryFrame, IsSplitBoundaryFrame, ...
    IsTrueSwitchAdjacentFrame, ...
    truthThreshold, spinnThreshold)

%% Plot 1: SPINN-D distribution by truth state
figure;
hold on;

maskSlow = validD & truthState == 1;
maskFast = validD & truthState == 2;

histogram(log10(SPINN_D(maskSlow)), 50, 'Normalization', 'probability');
histogram(log10(SPINN_D(maskFast)), 50, 'Normalization', 'probability');

xline(log10(spinnThreshold), '--', 'SPINN threshold');

xlabel('log_{10}(SPINN-D)');
ylabel('Probability');
title('SPINN-D distribution grouped by ground-truth state');
legend({'Truth slow', 'Truth fast', 'SPINN threshold'}, 'Location', 'best');
box on;

save_current_figure_safe(filePath, [baseName '_SPINN_D_distribution_by_truth_state']);

%% Plot 2: truth D distribution
figure;
hold on;

histogram(log10(D_truth(validD)), 50, 'Normalization', 'probability');
xline(log10(truthThreshold), '--', 'Truth threshold');

xlabel('log_{10}(D_{truth})');
ylabel('Probability');
title('Ground-truth D distribution');
box on;

save_current_figure_safe(filePath, [baseName '_D_truth_distribution']);

%% Plot 3: boundary vs non-boundary accuracy
groups = ["Non-boundary", "Any boundary", "Concat boundary", "Split boundary", "True-switch adjacent"];
acc = nan(5, 1);

masks = { ...
    validD & ~IsAnyBoundaryFrame, ...
    validD & IsAnyBoundaryFrame, ...
    validD & IsConcatBoundaryFrame, ...
    validD & IsSplitBoundaryFrame, ...
    validD & IsTrueSwitchAdjacentFrame};

for i = 1:5
    m = masks{i};
    if sum(m) > 0
        acc(i) = mean(predState(m) == truthState(m), 'omitnan');
    end
end

figure;
bar(acc);
set(gca, 'XTick', 1:5, 'XTickLabel', groups);
xtickangle(30);
ylim([0 1]);
ylabel('State classification accuracy');
title('State accuracy at boundary and switch-adjacent frames');
box on;

save_current_figure_safe(filePath, [baseName '_boundary_state_accuracy']);

%% Plot 4: SPINN-D vs D_truth
figure;
scatter(log10(D_truth(validD)), log10(SPINN_D(validD)), 8, '.');
hold on;
xline(log10(truthThreshold), '--');
yline(log10(spinnThreshold), '--');

xlabel('log_{10}(D_{truth})');
ylabel('log_{10}(SPINN-D)');
title('SPINN-D versus ground-truth D');
box on;

save_current_figure_safe(filePath, [baseName '_SPINN_D_vs_D_truth']);

%% Plot 5: boundary vs non-boundary SPINN-D distribution
figure;
hold on;

maskNonB = validD & ~IsAnyBoundaryFrame;
maskB = validD & IsAnyBoundaryFrame;

histogram(log10(SPINN_D(maskNonB)), 50, 'Normalization', 'probability');
histogram(log10(SPINN_D(maskB)), 50, 'Normalization', 'probability');

xline(log10(spinnThreshold), '--', 'SPINN threshold');

xlabel('log_{10}(SPINN-D)');
ylabel('Probability');
title('SPINN-D distribution: boundary vs non-boundary frames');
legend({'Non-boundary', 'Boundary', 'SPINN threshold'}, 'Location', 'best');
box on;

save_current_figure_safe(filePath, [baseName '_SPINN_D_boundary_vs_nonboundary']);

end

%% ============================================================
% Local function 12: safe figure saving
%% ============================================================
function save_current_figure_safe(filePath, outBaseName)

pngFile = fullfile(filePath, [outBaseName '.png']);
figFile = fullfile(filePath, [outBaseName '.fig']);

try
    exportgraphics(gcf, pngFile, 'Resolution', 300);
    fprintf('Figure saved to: %s\n', pngFile);
catch ME1
    warning('PNG 保存失败，尝试保存为 .fig。原因：%s', ME1.message);

    try
        savefig(gcf, figFile);
        fprintf('Figure saved to: %s\n', figFile);
    catch ME2
        warning('图像保存失败，但不影响 Excel 结果。错误信息：%s', ME2.message);
    end
end

end