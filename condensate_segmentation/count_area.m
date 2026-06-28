function analyze_droplet_demixing_final_nested()
%% ====================================
% Batch analysis of TDP43 / GR / GRme droplets and red demixed droplets
%
% Features:
% 1. Select TDP43 / GR / GRme images separately, with multiple images allowed for each class
% 2. Treat each image as an independent experiment
% 3. Quantify each image:
%    - Total droplet count
%    - Total droplet area
%    - Area of each total droplet
%    - Red demixed droplet count
%    - Red demixed droplet area
%    - Area of each red demixed droplet
% 4. Export Excel results
% 5. Export the segmentation overlay for the first image of each class
% 6. Export a dual-axis bar plot:
%    - Left y-axis: droplet count
%    - Right y-axis: total droplet area / demixed area
%    - mean +/- SEM
%    - Per-image scatter points
% 7. Use Welch's two-sample t-test for significance analysis
%
% Notes:
% - TDP43 is treated as red-only droplets by default; demixing is not quantified
% - Red-enriched regions in GR / GRme are treated as demixed droplets
% - The field of view is 127.28 um x 127.28 um by default
% ====================================

clc;
close all;

%% ===== 0. Parameter settings =====

FOV_um = 127.28;   % Actual field of view of the input image, in um

% ---------- Total droplet segmentation parameters ----------
total_smooth_sigma = 0.8;
total_min_area_um2 = 0.01;
total_fill_holes = true;

% ---------- Red demixed droplet segmentation parameters ----------
red_smooth_sigma = 0.8;
red_min_area_um2 = 0.01;
red_enrichment_ratio = 1.2;       % Red enrichment ratio relative to yellow/green
red_abs_sensitivity = 0.20;     % Sensitivity for the absolute red-intensity threshold

% ---------- Output control ----------
save_overlay_images = true;

%% ===== 1. Select images =====

classNames = {'TDP43','GR','GRme'};

fileList = cell(numel(classNames),1);
pathList = cell(numel(classNames),1);

for c = 1:numel(classNames)

    [files,pathName] = uigetfile( ...
        {'*.jpg;*.jpeg;*.png;*.tif;*.tiff', ...
        'Image files (*.jpg, *.jpeg, *.png, *.tif, *.tiff)'}, ...
        ['Select ', classNames{c}, ' images; multiple selection is allowed'], ...
        'MultiSelect','on');

    if isequal(files,0)
        warning('No images were selected for %s.', classNames{c});
        fileList{c} = {};
        pathList{c} = '';
    else
        if ischar(files)
            files = {files};
        end
        fileList{c} = files;
        pathList{c} = pathName;
    end

end

%% ===== 2. Select output Excel file =====

[outFile,outPath] = uiputfile( ...
    'Droplet_Demixing_Statistics.xlsx', ...
    'Select the output Excel file name');

if isequal(outFile,0)
    disp('Output canceled.');
    return;
end

excelFile = fullfile(outPath,outFile);

[~,baseName,~] = fileparts(excelFile);
outputFolder = fullfile(outPath,[baseName,'_Results']);

if ~exist(outputFolder,'dir')
    mkdir(outputFolder);
end

%% ===== 3. Batch analysis =====

summaryRows = {};
dropletRows = {};
demixRows = {};

summaryHeader = { ...
    'Class', ...
    'ImageName', ...
    'Width_px', ...
    'Height_px', ...
    'PixelSize_um', ...
    'TotalDropletCount', ...
    'TotalDropletArea_um2', ...
    'DemixDropletCount', ...
    'DemixDropletArea_um2'};

dropletHeader = { ...
    'Class', ...
    'ImageName', ...
    'DropletID', ...
    'Area_px', ...
    'Area_um2', ...
    'CentroidX_um', ...
    'CentroidY_um'};

demixHeader = { ...
    'Class', ...
    'ImageName', ...
    'DemixID', ...
    'Area_px', ...
    'Area_um2', ...
    'CentroidX_um', ...
    'CentroidY_um'};

allResults = struct();

for c = 1:numel(classNames)

    className = classNames{c};
    files = fileList{c};
    pathName = pathList{c};

    allResults.(className).totalArea = [];
    allResults.(className).demixArea = [];
    allResults.(className).totalCount = [];
    allResults.(className).demixCount = [];

    if isempty(files)
        continue;
    end

    for i = 1:numel(files)

        imgName = files{i};
        imgPath = fullfile(pathName,imgName);

        I = imread(imgPath);

        if size(I,3) == 1
            I = repmat(I,[1,1,3]);
        end

        [H,W,~] = size(I);

        pixelSize_um = FOV_um / W;
        pixelArea_um2 = pixelSize_um^2;

        isTDP43 = strcmp(className,'TDP43');

        result = analyze_single_image( ...
            I, ...
            pixelSize_um, ...
            total_smooth_sigma, ...
            total_min_area_um2, ...
            total_fill_holes, ...
            red_smooth_sigma, ...
            red_min_area_um2, ...
            red_enrichment_ratio, ...
            red_abs_sensitivity, ...
            isTDP43);

        % Summary results
        summaryRows(end+1,:) = { ...
            className, ...
            imgName, ...
            W, ...
            H, ...
            pixelSize_um, ...
            result.totalCount, ...
            result.totalArea_um2, ...
            result.demixCount, ...
            result.demixArea_um2};

        % Per-total-droplet details
        for k = 1:result.totalCount
            dropletRows(end+1,:) = { ...
                className, ...
                imgName, ...
                k, ...
                result.totalStats(k).Area, ...
                result.totalStats(k).Area * pixelArea_um2, ...
                result.totalStats(k).Centroid(1) * pixelSize_um, ...
                (H - result.totalStats(k).Centroid(2)) * pixelSize_um};
        end

        % Per-demixed-droplet details
        for k = 1:result.demixCount
            demixRows(end+1,:) = { ...
                className, ...
                imgName, ...
                k, ...
                result.demixStats(k).Area, ...
                result.demixStats(k).Area * pixelArea_um2, ...
                result.demixStats(k).Centroid(1) * pixelSize_um, ...
                (H - result.demixStats(k).Centroid(2)) * pixelSize_um};
        end

        allResults.(className).totalArea(end+1,1) = result.totalArea_um2;
        allResults.(className).demixArea(end+1,1) = result.demixArea_um2;
        allResults.(className).totalCount(end+1,1) = result.totalCount;
        allResults.(className).demixCount(end+1,1) = result.demixCount;

        % Export the segmentation overlay for the first image of each class
        if save_overlay_images && i == 1
            overlayFig = make_overlay( ...
                I, ...
                result.totalMask, ...
                result.demixMask, ...
                className, ...
                imgName);

            figBaseName = fullfile(outputFolder, ...
                [className,'_segmentation_overlay']);

            safe_save_fig(overlayFig,figBaseName);
            close(overlayFig);
        end

        fprintf('Done: %s - %s\n',className,imgName);

    end
end

%% ===== 4. Export Excel =====

if isempty(summaryRows)
    error('No images were selected. Program terminated.');
end

summaryTable = cell2table(summaryRows,'VariableNames',summaryHeader);
dropletTable = cell2table(dropletRows,'VariableNames',dropletHeader);
demixTable = cell2table(demixRows,'VariableNames',demixHeader);

writetable(summaryTable,excelFile,'Sheet','Summary');
writetable(dropletTable,excelFile,'Sheet','Each_Total_Droplet');
writetable(demixTable,excelFile,'Sheet','Each_Demix_Droplet');

%% ===== 5. Significance analysis: Welch's two-sample t-test =====

statsTable = do_statistics_all(allResults);
writetable(statsTable,excelFile,'Sheet','Statistics');

%% ===== 6. Plot dual-axis bar chart: count + area =====

fig = plot_summary_doublebar(allResults,statsTable);

summaryFigBaseName = fullfile(outputFolder,'Summary_DoubleBar_Count_Area');
safe_save_fig(fig,summaryFigBaseName);

disp(' ');
disp('Analysis complete.');
disp(['Excel output: ',excelFile]);
disp(['Image output folder: ',outputFolder]);

%% ============================================================
%                     Nested functions
% ============================================================

    function result = analyze_single_image( ...
            I, ...
            pixelSize_um, ...
            total_smooth_sigma, ...
            total_min_area_um2, ...
            total_fill_holes, ...
            red_smooth_sigma, ...
            red_min_area_um2, ...
            red_enrichment_ratio, ...
            red_abs_sensitivity, ...
            isTDP43)

        I_double = im2double(I);

        R = I_double(:,:,1);
        G = I_double(:,:,2);

        % ---------- Background subtraction ----------
        R_bg = imopen(R,strel('disk',15));
        G_bg = imopen(G,strel('disk',15));

        R_corr = R - R_bg;
        G_corr = G - G_bg;

        R_corr(R_corr < 0) = 0;
        G_corr(G_corr < 0) = 0;

        R_s = imgaussfilt(R_corr,total_smooth_sigma);
        G_s = imgaussfilt(G_corr,total_smooth_sigma);

        %% ---------- 1. Total droplet mask ----------

        totalSignal = max(R_s,G_s);

        positiveSignal = totalSignal(totalSignal > 0);

        if isempty(positiveSignal)
            totalMask = false(size(totalSignal));
        else
            T_total = graythresh(positiveSignal);
            totalMask = totalSignal > T_total;
        end

        totalMask = imopen(totalMask,strel('disk',1));
        totalMask = imclose(totalMask,strel('disk',2));

        if total_fill_holes
            totalMask = imfill(totalMask,'holes');
        end

        minTotalArea_px = round(total_min_area_um2 / pixelSize_um^2);
        totalMask = bwareaopen(totalMask,max(minTotalArea_px,3));

        totalMask = split_touching(totalMask);

        totalCC = bwconncomp(totalMask);
        totalStats = regionprops(totalCC,'Area','Centroid');

        totalCount = numel(totalStats);

        if totalCount > 0
            totalArea_um2 = sum([totalStats.Area]) * pixelSize_um^2;
        else
            totalArea_um2 = 0;
        end

        %% ---------- 2. Red demixed droplet mask ----------

        if isTDP43

            demixMask = false(size(totalMask));

        else

            R_d = imgaussfilt(R_corr,red_smooth_sigma);
            G_d = imgaussfilt(G_corr,red_smooth_sigma);

            % Absolute red-intensity threshold
            T_red_abs = adaptthresh(R_d,red_abs_sensitivity);
            redAbsMask = imbinarize(R_d,T_red_abs);

            % Approximate yellow as regions where R and G are both present
            yellow = min(R_s,G_s);

            % Regions with red enrichment relative to yellow/green
            redRatioMask = R_d > red_enrichment_ratio * max(G_d,yellow);

            demixMask = redAbsMask & redRatioMask;

            % Restrict to total droplets and nearby regions, while allowing independent red demixed droplets
            totalDilated = imdilate(totalMask,strel('disk',2));
            demixMask = demixMask & totalDilated;

            demixMask = imopen(demixMask,strel('disk',1));
            demixMask = imclose(demixMask,strel('disk',1));
            demixMask = imfill(demixMask,'holes');

            minRedArea_px = round(red_min_area_um2 / pixelSize_um^2);
            demixMask = bwareaopen(demixMask,max(minRedArea_px,2));

            demixMask = split_touching(demixMask);

        end

        demixCC = bwconncomp(demixMask);
        demixStats = regionprops(demixCC,'Area','Centroid');

        demixCount = numel(demixStats);

        if demixCount > 0
            demixArea_um2 = sum([demixStats.Area]) * pixelSize_um^2;
        else
            demixArea_um2 = 0;
        end

        %% ---------- 3. Return results ----------

        result.totalMask = totalMask;
        result.demixMask = demixMask;

        result.totalStats = totalStats;
        result.demixStats = demixStats;

        result.totalCount = totalCount;
        result.demixCount = demixCount;

        result.totalArea_um2 = totalArea_um2;
        result.demixArea_um2 = demixArea_um2;

    end

%% ============================================================
%                     Watershed split for adjacent droplets
% ============================================================

    function mask_out = split_touching(mask)

        if ~any(mask(:))
            mask_out = mask;
            return;
        end

        D = -bwdist(~mask);
        D(~mask) = -Inf;

        % Larger values make adjacent droplets less likely to split
        D2 = imhmin(D,1);

        L = watershed(D2);

        mask_out = mask;
        mask_out(L == 0) = 0;

    end

%% ============================================================
%                     Significance analysis: count and area
% ============================================================

    function statsTable = do_statistics_all(allResults)

        Comparison = {};
        Metric = {};
        Group1 = {};
        Group2 = {};
        PValue = [];
        Test = {};
        Significance = {};

        totalGroups = {'TDP43','GR','GRme'};
        totalPairs = nchoosek(1:3,2);

        % ---------- Total droplet count comparisons ----------
        for p = 1:size(totalPairs,1)

            g1 = totalGroups{totalPairs(p,1)};
            g2 = totalGroups{totalPairs(p,2)};

            x = allResults.(g1).totalCount;
            y = allResults.(g2).totalCount;

            [pval,testName] = compare_groups(x,y);

            Comparison{end+1,1} = [g1,' vs ',g2];
            Metric{end+1,1} = 'TotalDropletCount';
            Group1{end+1,1} = g1;
            Group2{end+1,1} = g2;
            PValue(end+1,1) = pval;
            Test{end+1,1} = testName;
            Significance{end+1,1} = p_to_star(pval);

        end

        % ---------- Total droplet area comparisons ----------
        for p = 1:size(totalPairs,1)

            g1 = totalGroups{totalPairs(p,1)};
            g2 = totalGroups{totalPairs(p,2)};

            x = allResults.(g1).totalArea;
            y = allResults.(g2).totalArea;

            [pval,testName] = compare_groups(x,y);

            Comparison{end+1,1} = [g1,' vs ',g2];
            Metric{end+1,1} = 'TotalDropletArea_um2';
            Group1{end+1,1} = g1;
            Group2{end+1,1} = g2;
            PValue(end+1,1) = pval;
            Test{end+1,1} = testName;
            Significance{end+1,1} = p_to_star(pval);

        end

        % ---------- Demixed droplet count comparison ----------
        x = allResults.GR.demixCount;
        y = allResults.GRme.demixCount;

        [pval,testName] = compare_groups(x,y);

        Comparison{end+1,1} = 'GR demix vs GRme demix';
        Metric{end+1,1} = 'DemixDropletCount';
        Group1{end+1,1} = 'GR_demix';
        Group2{end+1,1} = 'GRme_demix';
        PValue(end+1,1) = pval;
        Test{end+1,1} = testName;
        Significance{end+1,1} = p_to_star(pval);

        % ---------- Demixed droplet area comparison ----------
        x = allResults.GR.demixArea;
        y = allResults.GRme.demixArea;

        [pval,testName] = compare_groups(x,y);

        Comparison{end+1,1} = 'GR demix vs GRme demix';
        Metric{end+1,1} = 'DemixDropletArea_um2';
        Group1{end+1,1} = 'GR_demix';
        Group2{end+1,1} = 'GRme_demix';
        PValue(end+1,1) = pval;
        Test{end+1,1} = testName;
        Significance{end+1,1} = p_to_star(pval);

        statsTable = table( ...
            Comparison, ...
            Metric, ...
            Group1, ...
            Group2, ...
            PValue, ...
            Test, ...
            Significance);

    end

%% ============================================================
%                     Two-group comparison: Welch's two-sample t-test
% ============================================================

    function [pval,testName] = compare_groups(x,y)

        x = x(:);
        y = y(:);

        x = x(~isnan(x));
        y = y(~isnan(y));

        if numel(x) < 2 || numel(y) < 2
            pval = NaN;
            testName = 'Not enough replicates';
            return;
        end

        [~,pval] = ttest2(x,y, ...
            'Vartype','unequal', ...
            'Tail','both');

        testName = 'Welch''s two-sample t-test';

    end

%% ============================================================
%                     Convert p-value to significance stars
% ============================================================

    function star = p_to_star(p)

        if isnan(p)
            star = 'n.a.';
        elseif p < 0.0001
            star = '****';
        elseif p < 0.001
            star = '***';
        elseif p < 0.01
            star = '**';
        elseif p < 0.05
            star = '*';
        else
            star = 'ns';
        end

    end

%% ============================================================
%                     Plot dual-axis bar chart: count + area
% ============================================================

    function fig = plot_summary_doublebar(allResults,statsTable)

        groups = {'TDP43','GR','GRme','GR demix','GRme demix'};

        countData = { ...
            allResults.TDP43.totalCount, ...
            allResults.GR.totalCount, ...
            allResults.GRme.totalCount, ...
            allResults.GR.demixCount, ...
            allResults.GRme.demixCount};

        areaData = { ...
            allResults.TDP43.totalArea, ...
            allResults.GR.totalArea, ...
            allResults.GRme.totalArea, ...
            allResults.GR.demixArea, ...
            allResults.GRme.demixArea};

        nGroup = numel(groups);
        x = 1:nGroup;

        countMean = nan(1,nGroup);
        countSEM = nan(1,nGroup);
        areaMean = nan(1,nGroup);
        areaSEM = nan(1,nGroup);

        for i = 1:nGroup

            count_i = countData{i};
            count_i = count_i(~isnan(count_i));

            if ~isempty(count_i)
                countMean(i) = mean(count_i,'omitnan');
                if numel(count_i) > 1
                    countSEM(i) = std(count_i,'omitnan') / sqrt(numel(count_i));
                end
            end

            area_i = areaData{i};
            area_i = area_i(~isnan(area_i));

            if ~isempty(area_i)
                areaMean(i) = mean(area_i,'omitnan');
                if numel(area_i) > 1
                    areaSEM(i) = std(area_i,'omitnan') / sqrt(numel(area_i));
                end
            end

        end

        fig = figure('Color','w','Position',[100,100,1400,650]);

        offset = 0.20;
        barWidth = 0.34;

        countBarColor = [0.35 0.55 0.85];
        areaBarColor  = [0.90 0.45 0.20];

        countDotColor = [0.00 0.15 0.85];
        areaDotColor  = [0.85 0.10 0.10];

        rng(1);

        %% ---------- Left axis: count ----------
        yyaxis left
        hold on;

        bCount = bar(x - offset, ...
            countMean, ...
            barWidth, ...
            'FaceColor',countBarColor, ...
            'EdgeColor','k', ...
            'LineWidth',0.8);

        errorbar(x - offset, ...
            countMean, ...
            countSEM, ...
            'k', ...
            'LineStyle','none', ...
            'LineWidth',1.3, ...
            'CapSize',8);

        for i = 1:nGroup

            data_i = countData{i};
            data_i = data_i(~isnan(data_i));

            if isempty(data_i)
                continue;
            end

            jitter = (rand(size(data_i)) - 0.5) * 0.12;

            scatter(x(i) - offset + jitter, ...
                data_i, ...
                48, ...
                countDotColor, ...
                'filled', ...
                'MarkerFaceAlpha',0.75, ...
                'MarkerEdgeColor','k', ...
                'LineWidth',0.4);

        end

        ylabel('Droplet number');

        yl_left = ylim;
        if yl_left(2) <= 0 || isnan(yl_left(2))
            yl_left(2) = 1;
        end
        ylim([0 yl_left(2)*1.20]);

        %% ---------- Right axis: area ----------
        yyaxis right
        hold on;

        bArea = bar(x + offset, ...
            areaMean, ...
            barWidth, ...
            'FaceColor',areaBarColor, ...
            'EdgeColor','k', ...
            'LineWidth',0.8);

        errorbar(x + offset, ...
            areaMean, ...
            areaSEM, ...
            'k', ...
            'LineStyle','none', ...
            'LineWidth',1.3, ...
            'CapSize',8);

        for i = 1:nGroup

            data_i = areaData{i};
            data_i = data_i(~isnan(data_i));

            if isempty(data_i)
                continue;
            end

            jitter = (rand(size(data_i)) - 0.5) * 0.12;

            scatter(x(i) + offset + jitter, ...
                data_i, ...
                48, ...
                areaDotColor, ...
                'filled', ...
                'MarkerFaceAlpha',0.75, ...
                'MarkerEdgeColor','k', ...
                'LineWidth',0.4);

        end

        ylabel('Area (\mum^2)');

        yl_right = ylim;
        if yl_right(2) <= 0 || isnan(yl_right(2))
            yl_right(2) = 1;
        end

        yBase = yl_right(2) * 0.90;
        step = yl_right(2) * 0.08;

        % Annotate area significance by default
        add_sig_line_area( ...
            1 + offset, ...
            2 + offset, ...
            yBase, ...
            get_star(statsTable,'TotalDropletArea_um2','TDP43','GR'));

        add_sig_line_area( ...
            2 + offset, ...
            3 + offset, ...
            yBase + step, ...
            get_star(statsTable,'TotalDropletArea_um2','GR','GRme'));

        add_sig_line_area( ...
            1 + offset, ...
            3 + offset, ...
            yBase + 2*step, ...
            get_star(statsTable,'TotalDropletArea_um2','TDP43','GRme'));

        add_sig_line_area( ...
            4 + offset, ...
            5 + offset, ...
            yBase + 3*step, ...
            get_star(statsTable,'DemixDropletArea_um2','GR_demix','GRme_demix'));

        ylim([0, yBase + 4.5*step]);

        %% ---------- Plot formatting ----------
        set(gca, ...
            'XTick',x, ...
            'XTickLabel',groups, ...
            'FontSize',12, ...
            'LineWidth',1);

        xtickangle(20);
        box off;

        title('Droplet number and area quantification');

        legend([bCount,bArea], ...
            {'Droplet number','Area'}, ...
            'Location','northwest');

    end

%% ============================================================
%                     Get significance stars
% ============================================================

    function star = get_star(statsTable,metricName,g1,g2)

        idx = strcmp(statsTable.Metric,metricName) & ...
              strcmp(statsTable.Group1,g1) & ...
              strcmp(statsTable.Group2,g2);

        if any(idx)
            star = statsTable.Significance{find(idx,1)};
        else
            star = '';
        end

    end

%% ============================================================
%                     Add area significance line
% ============================================================

    function add_sig_line_area(x1,x2,y,star)

        if isempty(star)
            return;
        end

        plot([x1,x1,x2,x2], ...
            [y,y*1.02,y*1.02,y], ...
            'k-', ...
            'LineWidth',1.2);

        text(mean([x1,x2]), ...
            y*1.035, ...
            star, ...
            'HorizontalAlignment','center', ...
            'VerticalAlignment','bottom', ...
            'FontSize',12, ...
            'FontWeight','bold');

    end

%% ============================================================
%                     Generate segmentation overlay
% ============================================================

    function fig = make_overlay(I,totalMask,demixMask,className,imgName)

        fig = figure('Color','w','Position',[100,100,1200,400]);

        subplot(1,3,1);
        imshow(I);
        title([className,' original'],'Interpreter','none');

        subplot(1,3,2);
        imshow(I);
        hold on;
        visboundaries(totalMask,'Color','g','LineWidth',0.8);
        title('Total droplets boundary');

        subplot(1,3,3);
        imshow(I);
        hold on;
        visboundaries(totalMask,'Color','g','LineWidth',0.8);
        visboundaries(demixMask,'Color','r','LineWidth',0.8);
        title('Total droplets + demixed droplets');

        sgtitle([className,' | ',imgName],'Interpreter','none');

    end

%% ============================================================
%                     Save figure safely
% ============================================================

    function safe_save_fig(figHandle,baseFileName)

        try
            savefig(figHandle,[baseFileName,'.fig']);
        catch ME
            warning('Failed to save FIG: %s',ME.message);
        end

        try
            if exist('exportgraphics','file') == 2
                exportgraphics(figHandle,[baseFileName,'.png'],'Resolution',300);
            else
                warning('The current MATLAB version does not support exportgraphics, so only the FIG file was saved.');
            end
        catch ME
            warning('Failed to export PNG, but the program will continue. Reason: %s',ME.message);
        end

    end

end
