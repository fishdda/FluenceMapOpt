classdef FluenceMapOpt < handle
    % FLUENCEMAPOPT Fluence map optimization with dose-volume constraints.
    %
    %   Problem statement:
    % 
    %   min_(x,w) 
    %       sum(i in I) weight_i/(2*nVoxels_i)*||A_i*x - d_i||_2^2
    %       + sum(j in J) weight_j/(2*nVoxels_j)*||w_j - (A_j*x - d_j)||_2^2
    %       + lambda/2*||x||_2^2
    %   s.t. 
    %       x >= 0
    %       ||max(0,w_j)||_0 <= nVoxels_j*percent_j/100 for all j in J
    %   where
    %       I = set of uniform dose targets
    %       J = set of dose-volume constraints
    %
    %   For each body structure included in the treatment plan, create a
    %   structure with the following fields:
    %
    %       name: string used in data files
    %       terms: cell containing organ constraint terms
    %
    %   Each term should have the following fields:
    %
    %       type: string 'unif', 'ldvc', or 'udvc'
    %       weight: coefficient of the term in the objective function
    %       dose: dose in Gy
    %       percent: include if type is 'ldvc' or 'udvc':
    %           * 'ldvc': No more than p% receives less than d Gy
    %           * 'udvc': No more than p% receives more than d Gy
    %
    %   Written to work with the CORT prostate tumor dataset, but could be
    %   modified to work with other datasets.
    
    properties (SetAccess = private)
        structs            % Body structures
        angles = 0:52:358; % Gantry angles
        overlap = false;   % Allow overlaps in structures
        lambda = 1e-8;     % L2 regularization coefficient
        nStructs           % Number of body structures
        nAngles            % Number of angles
        nBeamlts           % Number of beamlets
    end
    
    properties (Access = private)
        D     % Full beamlet-to-voxel matrix
        A     % Stacked beamlet-to-voxel matrix
        H     % Stacked beamlet-to-voxel Hessian
        Au    % Stacked beamlet-to-voxel matrix for uniform target terms
        Hu    % Stacked beamlet to voxel Hessian for uniform target terms
        du    % Stacked dose vector for uniform target terms
        lb    % Lower bound for beamlets
        ub    % Upper bound for beamlets
        names % Body structure names
        mask  % Body structure contours for plotting     
    end

    properties
        x0             % Initial beamlet intensities
        x              % Final beamlet intensities
        obj            % Objective function values
        wDiff          % Convergence criteria
        nIter          % Number of iterations used
        time           % Time to compute solution (seconds)
        tol = 1e-3;    % Stopping tolerance
        maxIter = 500; % Maximum number of iterations
    end
    
    methods
        function prob = FluenceMapOpt(structs,varargin)
            % FLUENCEMAPOPT Initialize problem.
            %
            %   prob = FluenceMapOpt(structs)
            %       Initialize problem with default parameters.
            %
            %   prob = FluenceMapOpt(structs,ProbSpec)
            %       Initialize problem with optional arguments.
            %
            %   Example:
            %       prob = FluenceMapOpt(structs,...
            %           'angles',0:52:358,...
            %           'overlap',false,...
            %           'lambda',1e-8,...
            %           'x0',zeros(986,1),...
            %           'tol',1e-3,...
            %           'maxIter',500);
        
            % Set input variables
            if nargin == 0
                error('Not enough input arguments.')
            end
            if ~iscell(structs)
                error('Invalid input for `structs`.')
            end
            prob.setInputVars(varargin);
            prob.nStructs = length(structs);
            prob.nAngles = length(prob.angles);
            
            % Comput internal variables
            [prob.D,prob.nBeamlts] = FluenceMapOpt.getD(prob.angles);
            prob.structs = FluenceMapOpt.getStructVars(structs,...
                prob.nStructs,prob.overlap,prob.D);
            prob.names = FluenceMapOpt.getNames(prob.structs,prob.nStructs);
            prob.mask = FluenceMapOpt.getMaskStruct(prob.names,prob.overlap);
            [prob.A,prob.H,prob.lb,prob.ub] = prob.getA('full');
            [prob.Au,prob.Hu,~,~] = prob.getA('unif');
            prob.du = prob.getd('unif');
            
            % Compute initial beamlets
            if isempty(prob.x0)
                prob.x0 = prob.projX('unif');
            end
        end
        
        function calcBeamlets(prob,print)
            % CALCBEAMLETS Calculate beamlet intensities.
            if nargin == 1
                print = true;
            end
            
            % Fluence map optimization
            tic;
            prob.initProb(print);
            for kk = 1:prob.maxIter
                
                % Update x and w vectors
                prob.x = prob.projX('full');
                wDiffSum = 0;
                for ii = 1:prob.nStructs
                    for jj = 1:prob.structs{ii}.nTerms
                        if ~strcmp(prob.structs{ii}.terms{jj}.type,'unif')
                            wDiffSum = wDiffSum + prob.updateW(ii,jj);
                        end
                    end
                end
                
                % Calculate objective
                prob.nIter = kk;
                prob.calcObj(kk,print);
                prob.wDiff(kk) = wDiffSum;
                if print
                    fprintf(', wDiff: %7.4e\n',wDiffSum);
                end
                
                % Check convergence
                if wDiffSum <= prob.tol
                    prob.time = toc;
                    prob.obj = prob.obj(1:prob.nIter+1);
                    prob.wDiff = prob.wDiff(1:prob.nIter);
                    break
                end
            end
        end
        
        function plotObj(prob)
            % PLOTOBJ Plot objective function values.
            
            % Objective function
            figure()
            subplot(1,2,1)
            plot(0:prob.nIter,prob.obj,'LineWidth',2)
            xlabel('Iteration (k)')
            ylabel('Objective Value')
            
            % Convergence of proxy variables
            subplot(1,2,2)
            plot(1:prob.nIter,prob.wDiff,'LineWidth',2)
            xlabel('Iteration (k)')
            ylabel('Convergence Criteria')
        end
        
        function plotDVH(prob)
            % PLOTDVH Plot dose-volume histogram.
            
            % Compute curves and initialize
            [doses,dvhInit,dvhFinal] = prob.calcDVH();
            myLines = lines;
            legendHandles = [];
            figure(), hold on
            
            % Plot curves and targets/constraints
            for ii = 1:prob.nStructs
               plot(doses,dvhInit(ii,:),'--','Color',myLines(ii,:),...
                   'LineWidth',2)
               for jj = 1:prob.structs{ii}.nTerms
                   isUnif = strcmp(prob.structs{ii}.terms{jj}.type,'unif');
                   if ~isUnif && prob.structs{ii}.terms{jj}.percent == 0
                       % Plot star at maximum dose value
                       plot(prob.structs{ii}.terms{jj}.dose,0,'p',...
                           'MarkerFaceColor',[0.9290 0.6940 0.1250],...
                           'MarkerEdgeColor',[0.9290 0.6940 0.1250],...
                           'MarkerSize',10);
                   else
                       % Get vertical coordinates of targets/constraints
                       if isUnif
                           percent = [0 100 100];
                       elseif prob.structs{ii}.terms{jj}.percent > 0
                           percent = zeros(1,3);
                           percent(2:3) = prob.structs{ii}.terms{jj}.percent;
                       end
                       % Get horizontal coordinates of targets/constraints
                       dose = zeros(1,3);
                       dose(1:2) = prob.structs{ii}.terms{jj}.dose;
                       plot(dose,percent,':','Color',[0.4,0.4,0.4],...
                           'LineWidth',2)
                   end
                   if jj == 1
                       dvhHandle = plot(doses,dvhFinal(ii,:),...
                           'Color',myLines(ii,:),'LineWidth',2);
                       legendHandles = [legendHandles dvhHandle];
                   else
                       plot(doses,dvhFinal(ii,:),'Color',myLines(ii,:),...
                           'LineWidth',2)
                   end 
               end
            end
                
            % Annotations
            legend(legendHandles,prob.names)
            xlabel('Dose (Gy)')
            ylabel('Relative Volume (%)')
            ax = gca;
            ax.XLim = [0 doses(end)];
            ax.YLim = [0 100];
            box on
            axis square
        end
        
        function plotBeams(prob)
            %PLOTBEAMS Plot beamlet intensities.
            figure()
            xRemain = prob.x;
            for ii = 1:prob.nAngles
                % Get beamlet intensities
                [idx,nX,nY] = FluenceMapOpt.getBeamCoords(prob.angles(ii));
                xCurrent = xRemain(1:length(idx));
                xRemain = xRemain(length(idx)+1:end);
                beam = zeros(nX,nY);
                beam(idx) = xCurrent;
                beam = beam';
                
                % Plot beamlet intensities
                subplot(1,prob.nAngles,ii)
                imagesc(beam), colormap gray
                beamAngle = sprintf('%d^\\circ',prob.angles(ii));
                title(beamAngle,'Interpreter','tex')
                caxis([0 max(prob.x)])
                axis square
            end
            
            % Add colorbar
            pos = get(subplot(1,prob.nAngles,ii),'Position');
            cb = colorbar;
            cb.Label.String = 'Beamlet Intensity (MU)';
            set(subplot(1,prob.nAngles,ii),'Position',pos);
        end
        
        function plotDose(prob)
            % PLOTDOSE Plot dose with slider for z position.
            figure()
            warning('off','MATLAB:contour:ConstantData');
            hax = axes('Units','pixels');
            
            % Plot dose at z = 50
            z = 50;
            dose = reshape(prob.D*prob.x,184,184,90);
            imagesc(dose(:,:,z),'AlphaData',dose(:,:,z)~=0), hold on
            
            % Plot body structure outlines
            for ii = 1:length(prob.mask)
                contour(prob.mask{ii}(:,:,z),1,'k');
            end
            
            % Annotations
            title(sprintf('z = %d',z))
            caxis([min(dose(:)) max(dose(:))]);
            cb = colorbar;
            cb.Label.String = 'Dose (Gy)';
            axis equal
            axis off
            hold off
            
            % Add slider
            uicontrol('Style','slider',...
                'Min',1,'Max',90,'Value',z,...
                'Position',[200 20 120 20],...
                'Callback',{@prob.updateZ,hax,dose}); 
        end
         
        function saveResults(prob,fileName)
            % SAVERESULTS current state and results.
            results = struct('structs',prob.structs,...
                'angles',prob.angles,...
                'lambda',prob.lambda,...
                'overlap',prob.overlap,...
                'x0',prob.x0,...
                'x',prob.x,...
                'obj',prob.obj,...
                'wDiff',prob.wDiff,...
                'nIter',prob.nIter,...
                'time',prob.time,...
                'tol',prob.tol,...
                'maxIter',prob.maxIter);
            save(fileName,'results');
        end
    end
    
    methods (Hidden)
        function setInputVars(prob,args)
            % SETINPUTVARS Set input variables.
            for ii = 1:length(args)/2
                prob.(args{2*ii-1}) = args{2*ii};
            end
        end 
        
        function [A,H,lb,ub] = getA(prob,type)
            % GETA Get stacked beamlet-to-voxel matrix, Hessian, and 
            %   beamlet lower and upper bounds.
            %
            %   Get output for structures and terms specified by type:
            %       * 'full': All structures and terms
            %       * 'unif': Structures and terms with uniform targets
            matFull = strcmp(type,'full');
            matUnif = strcmp(type,'unif');

            % Add terms
            A = [];
            for ii = 1:prob.nStructs
                nVoxels = prob.structs{ii}.nVoxels;
                for jj = 1:prob.structs{ii}.nTerms
                    termUnif = strcmp(prob.structs{ii}.terms{jj}.type,'unif');
                    if matFull || (matUnif && termUnif)
                        weight = prob.structs{ii}.terms{jj}.weight;
                        temp = sqrt(weight/nVoxels)*prob.structs{ii}.A;
                        A = [A; temp];
                    end
                end
            end

            % Add regularization
            if prob.lambda > 0
                A = [A; sqrt(prob.lambda)*eye(prob.nBeamlts)];
            end

            % Create Hessian and beamlet bounds
            H = A'*A;
            lb = zeros(prob.nBeamlts,1);
            ub = inf(prob.nBeamlts,1);
        end
        
        function d = getd(prob,type)
            % GETD Get stacked dose vector.
            %
            %   Get output for structurs and terms specified by type:
            %       * 'full':  All structures and terms
            %       * 'unif': Structures and terms with uniform targets
            vecFull = strcmp(type,'full');
            vecUnif = strcmp(type,'unif');

            % Add terms
            d = [];
            for ii = 1:prob.nStructs
                nVoxels = prob.structs{ii}.nVoxels;
                for jj = 1:prob.structs{ii}.nTerms
                    termUnif = strcmp(prob.structs{ii}.terms{jj}.type,'unif');
                    if vecFull || (vecUnif && termUnif)
                        weight = prob.structs{ii}.terms{jj}.weight;
                        termD = prob.structs{ii}.terms{jj}.d;
                        temp = sqrt(weight/nVoxels)*termD;
                        if ~termUnif
                            w = prob.structs{ii}.terms{jj}.w;
                            temp = temp + sqrt(weight/nVoxels)*w;
                        end
                        d = [d; temp];
                    end
                end
            end

            % Add regularization
            if prob.lambda > 0
                d = [d; zeros(prob.nBeamlts,1)];
            end
        end
        
        function x = projX(prob,type)
            % PROJX Solve non-negative least-squares problem for beamlets.
            if strcmp(type,'unif')
                A = prob.Au;
                H = prob.Hu;
                d = prob.du;
                x0 = zeros(prob.nBeamlts,1);
            else
                A = prob.A;
                H = prob.H;
                d = prob.getd('full');
                x0 = prob.x;
            end
            f = -A'*d;
            func = @(x)FluenceMapOpt.quadObj(x,H,f);
            options.verbose = 0;
            options.method = 'newton';
            x = minConf_TMP(func,x0,prob.lb,prob.ub,options);
        end
        
        function initProb(prob,print)
            % INITPROB Initialize x, w, and objective values.
            prob.x = prob.x0;
            prob.initW();
            prob.initObj();
            prob.calcObj(0,print);
        end

        function initW(prob)
            % INITW Initialize w vectors for dose-volume constraint terms.
            for ii = 1:prob.nStructs
                for jj = 1:prob.structs{ii}.nTerms
                    if ~strcmp(prob.structs{ii}.terms{jj}.type,'unif')
                        initDose = prob.structs{ii}.A*prob.x0;
                        res = initDose - prob.structs{ii}.terms{jj}.d;
                        s = strcmp(prob.structs{ii}.terms{jj}.type,'ldvc');
                        k = prob.structs{ii}.terms{jj}.k;
                        w = FluenceMapOpt.projW((-1)^s*res,k);
                        prob.structs{ii}.terms{jj}.w = w;
                   end
                end
            end
        end
        
        function initObj(prob)
            % INITOBJ Initialize objective function values
            zeroVec = zeros(1,prob.maxIter+1);
            prob.obj = zeroVec;
            prob.wDiff = zeroVec(1:end-1);
            for ii = 1:prob.nStructs
                for jj = prob.structs{ii}.nTerms
                    prob.structs{ii}.terms{jj}.obj = zeroVec;
                    if ~strcmp(prob.structs{ii}.terms{jj}.type,'unif')
                        prob.structs{ii}.terms{jj}.resPos = zeroVec;
                        prob.structs{ii}.terms{jj}.wPos = zeroVec;
                    end
                end
            end
        end
        
        function calcObj(prob,iter,print)
            % CALCOBJ Calculate and print objective function values.
            for ii = 1:prob.nStructs
                nVoxels = prob.structs{ii}.nVoxels;
                for jj = 1:prob.structs{ii}.nTerms
                    weight = prob.structs{ii}.terms{jj}.weight;
                    dose = prob.structs{ii}.A*prob.x;
                    res = dose - prob.structs{ii}.terms{jj}.d;
                    if ~strcmp(prob.structs{ii}.terms{jj}.type,'unif')
                        s = strcmp(prob.structs{ii}.terms{jj}.type,'ldvc');
                        resPos = 100*sum((-1)^s*res > 0)/nVoxels;
                        prob.structs{ii}.terms{jj}.dPos(iter+1) = resPos;
                        wPos = 100*sum(prob.structs{ii}.terms{jj}.w > 0)/nVoxels;
                        prob.structs{ii}.terms{jj}.wPos(iter+1) = wPos;
                        res = res - prob.structs{ii}.terms{jj}.w; 
                    end
                    termObj = weight*norm(res)^2/(2*nVoxels);
                    prob.structs{ii}.terms{jj}.obj(iter+1) = termObj;
                    prob.obj(iter+1) = prob.obj(iter+1) + termObj;
                end
            end
            prob.obj(iter+1) = prob.obj(iter+1) + prob.lambda*norm(prob.x)^2/2;
            if print
                fprintf('iter: %d, obj: %7.4e',iter,prob.obj(iter+1));
                if iter == 0
                    fprintf('\n');
                end
            end 
        end
        
        function wDiff = updateW(prob,ii,jj)
            % UPDATEW Update proxy variable.
            
            % Grab variables
            s = strcmp(prob.structs{ii}.terms{jj}.type,'ldvc');
            k = prob.structs{ii}.terms{jj}.k;
            step = prob.structs{ii}.terms{jj}.step;
            coeff = step*prob.structs{ii}.terms{jj}.weight/prob.structs{ii}.nVoxels;
            
            % Calculate gradient step
            dose = prob.structs{ii}.A*prob.x;
            res = (-1)^s*(dose - prob.structs{ii}.terms{jj}.d);
            wPrev = prob.structs{ii}.terms{jj}.w;
            wStep = wPrev + coeff*(res - wPrev);
            
            % Project onto set ||(w)_+||_0 <= k
            wProj = FluenceMapOpt.projW(wStep,k);
            wDiff = norm(wProj - wPrev)/step;
            prob.structs{ii}.terms{jj}.w = wProj;
        end
        
        function [doses,dvhInit,dvhFinal] = calcDVH(prob)
            % CALCDVH Calculate dose-volume histograms.
            nPoints = 1000;
            doses = linspace(0,100,nPoints);
            dvhInit = zeros(prob.nStructs,nPoints);
            dvhFinal = zeros(prob.nStructs,nPoints);
            for ii = 1:prob.nStructs
                doseInit = prob.structs{ii}.A*prob.x0;
                doseFinal = prob.structs{ii}.A*prob.x;
                nVoxels = prob.structs{ii}.nVoxels;
                for jj = 1:nPoints
                   dvhInit(ii,jj) = 100*sum(doseInit >= doses(jj))/nVoxels;
                   dvhFinal(ii,jj) = 100*sum(doseFinal >= doses(jj))/nVoxels;
                end
            end       
        end
        
        function updateZ(prob,hObj,~,~,dose)
            % UPDATEZ Callback function for plotDose() slider.
            
            % Plot dose at current z value
            z = round(get(hObj,'Value'));
            imagesc(dose(:,:,z),'AlphaData',dose(:,:,z)~=0), hold on
            
            % Plot body structure outlines
            for ii = 1:length(prob.mask)
                contour(prob.mask{ii}(:,:,z),1,'k');
            end
            
            % Annotations
            title(sprintf('z = %d',z))
            caxis([min(dose(:)) max(dose(:))]);
            cb = colorbar;
            cb.Label.String = 'Dose (Gy)';
            axis equal
            axis off
            hold off
        end
    end
    
    methods (Hidden, Static)
        function [D,nBeamlts] = getD(angles)
            % GETD Get full beamlet-to-voxel matrix.
            temp = [];
            for ii = angles
                load(['Gantry' int2str(ii) '_Couch0_D.mat']);
                temp = [temp D];
            end
            D = temp;
            nBeamlts = size(D,2);
        end

        function structs = getStructVars(structs,nStructs,overlap,D)
            % GETSTRUCTVARS Get structure-specific variables.
            vPrev = [];
            for ii = 1:nStructs
                load([structs{ii}.name '_VOILIST.mat']);
                if ~overlap
                    [v,vPrev] = FluenceMapOpt.removeOverlap(v,vPrev); 
                end
                structs{ii}.A = D(v,:);
                structs{ii}.nVoxels = length(v);
                structs{ii}.nTerms = length(structs{ii}.terms);
                structs{ii}.terms = FluenceMapOpt.getTermVars(structs{ii}.terms,...
                    structs{ii}.nTerms,structs{ii}.nVoxels);
            end
        end
        
        function [v,vPrev] = removeOverlap(v,vPrev)
            % REMOVEOVERLAP Remove overlapping voxels from body structure.
           if isempty(vPrev)
               vPrev = v;
           else
               v = setdiff(v,vPrev);
               vPrev = union(v,vPrev);
           end 
        end

        function terms = getTermVars(terms,nTerms,nVoxels)
            % GETTERMVARS Get term-specific variables.
            for ii = 1:nTerms
                terms{ii}.d = terms{ii}.dose*ones(nVoxels,1);
                terms{ii}.step = nVoxels/terms{ii}.weight;
                if ~strcmp(terms{ii}.type,'unif')
                    % number of voxels allowed to be < or > dose
                    terms{ii}.k = floor(terms{ii}.percent*nVoxels/100);
                end
            end
        end

        function names = getNames(structs,nStructs)
            % GETNAMES Get body structure names.
            names = cell(1,nStructs);
            for ii = 1:nStructs
                names{ii} = structs{ii}.name;
            end
        end

        function mask = getMaskStruct(names,overlap)
            % GETMASKSTRUCT Get body structure contours for all organs.
            vPrev = [];
            for ii = 1:length(names)
               load([names{ii} '_VOILIST.mat']);
               if ~overlap
                   [v,vPrev] = FluenceMapOpt.removeOverlap(v,vPrev); 
               end
               mask{ii} = FluenceMapOpt.getMask(v);
            end
            if ~any(strcmp(names,'BODY'))
                load('BODY_VOILIST.mat');
                mask{ii+1} = FluenceMapOpt.getMask(v);
            end
        end

        function mask = getMask(v)
            % GETMASK Get body structure contour for one organ.
            mask = zeros(184*184*90,1);
            mask(v) = 1;
            mask = reshape(mask,184,184,90);
        end
        
        function [fVal,gVal,hVal] = quadObj(x,H,f)
           % Objective function for non-negative least-squares problem.
           Hx = H*x;
           fVal = x'*(0.5*Hx + f);
           gVal = Hx + f;
           hVal = H;
        end

        function w = projW(w,k)
            % PROJW Project w onto the set satisfying ||max(0,w)||_0 <= k.
            idxPos = w > 0;
            if sum(idxPos) > k
                wPos = w(idxPos);
                [~,idxSort] = sort(wPos,'descend');
                wPos(idxSort(k+1:end)) = 0;
                w(idxPos) = wPos;
            end
        end
        
        function [idx,nX,nY] = getBeamCoords(angle)
            % GETBEAMCOORDS Get beamlet coordinates.
            load(['Gantry' int2str(angle) '_Couch0_BEAMINFO.mat']);
            xIdx = x - min(x) + 1;
            yIdx = y - min(y) + 1;
            nX = max(xIdx);
            nY = max(yIdx);
            idx = sub2ind([nX,nY],xIdx,yIdx);
        end
        
        % not implemented...
        function otherMethods()
%         % Constraint generation method.
%         function constGen(f)      
%             
%             [A_dvc,d_dvc] = f.calcConstMatBig(f.xInit);
%             f.x = lsqlin(f.A_unif,f.d_unif,A_dvc,d_dvc,[],[],f.lb,f.ub);
%         end
%         
%         % Calculate stacked constraint matrix for dose-volume constraints.
%         function [A_dvc,d_dvc] = calcConstMatBig(f,x)
%            
%             A_dvc = [];
%             d_dvc = [];
%             for i = 1:f.nStructs
%                 for j = 1:f.structs{i}.nTerms
%                     if ~strcmp(f.structs{i}.terms{j}.type,'unif')
%                         [A_temp,d_temp] = calcConstMatSmall(f,x,i,j);
%                         A_dvc = [A_dvc; A_temp];
%                         d_dvc = [d_dvc; d_temp];
%                     end
%                 end
%             end
%         end
%         
%         % Calculate constraint matrix for dose-volume constraint.
%         function [A_dvc,d_dvc] = calcConstMatSmall(f,x,struct,term)
%             
%             [~,idx] = sort(f.structs{struct}.A*x);
%             if strcmp(f.structs{struct}.terms{term}.type,'udvc')
%                 idx_lower = f.structs{struct}.nVoxels - f.structs{struct}.terms{term}.k;
%                 A_dvc = f.structs{struct}.A(idx(1:idx_lower),:);
%                 d_dvc = f.structs{struct}.terms{term}.d(idx(1:idx_lower));
%             elseif strcmp(f.structs{struct}.terms{term}.type,'ldvc')
%                 idx_upper = f.structs{struct}.terms{term}.k + 1;
%                 A_dvc = -f.structs{struct}.A(idx(idx_upper:end),:);
%                 d_dvc = -f.structs{struct}.terms{term}.d(idx(idx_upper:end));
%             else
%                 A_dvc = NaN;
%                 d_dvc = NaN;
%             end 
%         end
%         
%         % conrad method.
%         function conrad(f,slope)
%             
%             if ~exist('slope','var')
%                 slope = 1;
%             end
% 
%             % Non-negative least-squares with relaxed OAR constraint
%             cvx_begin quiet
%                 variable x1(f.nBeamlts)
%                 minimize( sum_square(f.A_unif*x1 - f.d_unif) )
%                 subject to
%                     f.lb <= x1;
%                     for i = 1:f.nStructs
%                         for j = 1:f.structs{i}.nTerms
%                             if ~strcmp(f.structs{i}.terms{j}.type,'unif')
%                                 A = f.structs{i}.A;
%                                 d = f.structs{i}.terms{j}.d;
%                                 if strcmp(f.structs{i}.terms{j}.type,'udvc')
%                                     k = f.structs{i}.nVoxels - f.structs{i}.terms{j}.k;
%                                 else
%                                     k = f.structs{i}.terms{j}.k;
%                                 end
%                                 sum(pos(1 + slope*(A*x1 - d))) <= k;
%                             end
%                         end
%                     end
%             cvx_end
% 
%             % Non-negative least-squares with hard OAR constraint
%             cvx_begin quiet
%                 variable x2(f.nBeamlts)
%                 minimize( sum_square(f.A_unif*x2 - f.d_unif) )
%                 subject to
%                     f.lb <= x2;
%                     for i = 1:f.nStructs
%                         for j = 1:f.structs{i}.nTerms
%                             if ~strcmp(f.structs{i}.terms{j}.type,'unif')
%                                 [A,d] = calcConstMatSmall(f,x1,i,j);
%                                 A*x2 <= d;
%                             end
%                         end
%                     end
%             cvx_end
%             
%             f.x = x2;
%         end
        end
        
        % not implemented...
        function paperPlots()
%         % Plot objective function values (fig 8).
%         function plotObjPaper(f)
%             
%             myLines = lines;
%            
%             % Objective function
%             figure(1)
%             subplot(3,1,1)
%             plot(0:f.nIter,f.obj(1:f.nIter+1),'Color',[0.5,0.5,0.5],'LineWidth',3)
%             f.adjustAxis(gca)
%             
%             % Objective terms
%             for i = 1:f.nStructs
%                 for j = 1:length(f.structs{i}.terms)
%                     figure(1)
%                     subplot(3,1,i+1)
%                     plot(0:f.nIter,f.structs{i}.terms{j}.obj(1:f.nIter+1),'Color',myLines(i,:),'LineWidth',3);
%                     f.adjustAxis(gca)
%             
%                     % Voxels under or over dose constraints
%                     if ~strcmp(f.structs{i}.terms{j}.type,'unif')
%                         figure(2), hold on
%                         subplot(2,1,2)
%                         plot(0:f.nIter,f.structs{i}.terms{j}.vdiff(1:f.nIter+1),'Color',myLines(i,:),'LineWidth',3);
%                         f.adjustAxis(gca)
%                         set(gca,'YTick',52:2:56);
%                     end
%                 end
%             end
%             
%             figure(2)
%             subplot(2,1,1)
%             plot(1:f.nIter,f.err(1:f.nIter),'Color',[0.5,0.5,0.5],'LineWidth',3)
%             f.adjustAxis(gca);
%         end   
%         
%         % Readjust axes limits.
%         function adjustAxis(~,g)
%             
%             axis tight
%             yVals = g.YLim;
%             yPad = 0.1*(yVals(2) - yVals(1));
%             g.YLim = [yVals(1)-yPad yVals(2)+yPad];
%             g.XTick = 0:50:200;
%             g.XTickLabels = {};
%             g.YTickLabels = {};
%             g.LineWidth = 2;      
%         end
%         
%         % Calculate and plot dose-volume histogram of solution (fig 9,11,12,13).
%         function plotDVHPaper(f)
%             
%             myLines = lines;
%             
%             % Calculate dose-volume histograms
%             doses = linspace(0,100,1000);
%             dvhInit = zeros(f.nStructs,length(doses));
%             dvhFinal = zeros(f.nStructs,length(doses));
%             for i = 1:f.nStructs
%                 doseInit = f.structs{i}.A*f.xInit;
%                 doseFinal = f.structs{i}.A*f.x;
%                 for j = 1:length(doses)
%                     dvhInit(i,j) = 100*sum(doseInit > doses(j))/f.structs{i}.nVoxels;
%                     dvhFinal(i,j) = 100*sum(doseFinal > doses(j))/f.structs{i}.nVoxels;
%                 end
%             end
%             
%             % Plot dose-volume histograms
%             for i = 1:f.nStructs
%                 figure(), hold on
%                 for j = 1:length(f.structs{i}.terms)
%                     if ~strcmp(f.structs{i}.terms{j}.type,'unif') && f.structs{i}.terms{j}.percent == 0
%                         plot(f.structs{i}.terms{j}.dose,0,'p','MarkerFaceColor',[0.9290 0.6940 0.1250],...
%                             'MarkerEdgeColor',[0.9290 0.6940 0.1250],'MarkerSize',10);
%                     else
%                         if strcmp(f.structs{i}.terms{j}.type,'unif')
%                             percent = [0 100 100];
%                         elseif f.structs{i}.terms{j}.percent > 0
%                             percent = zeros(1,3);
%                             percent(2:3) = f.structs{i}.terms{j}.percent;
%                         end
%                         dose = zeros(1,3);
%                         dose(1:2) = f.structs{i}.terms{j}.dose;
%                         plot(dose,percent,':','Color',[0.4 0.4 0.4],'LineWidth',3)
%                         plot(doses,dvhInit(i,:),'--','LineWidth',3,'Color',myLines(i,:))
%                         plot(doses,dvhFinal(i,:),'LineWidth',3,'Color',myLines(i,:))
%                     end
%                 end
%                 
%                 % Annotations
%                 ax = gca;
%                 ax.XLim = [0 doses(end)];
%                 ax.YLim = [0 100];
%                 ax.XTick = 0:20:100;
%                 ax.YTick = 0:20:100;
%                 ax.XTickLabel = {};
%                 ax.YTickLabel = {};
%                 ax.LineWidth = 2;
%                 box on
%                 axis square
%             end
%         end
%               
%         % Plot beamlet intensities (fig 10,14).
%         function plotBeamletsPaper(f)
%             
%             figure()
%             x = f.x;
%             
%             for i = 1:4
%                 % Get x and y positions
%                 [linIdx,nx,ny] = f.getBeamlets(f.angles(i));
%                 
%                 % Get beamlet intensities
%                 xTemp = x(1:length(linIdx));
%                 x = x(length(linIdx)+1:end);
%                 B = zeros(nx,ny);
%                 B(linIdx) = xTemp;
%                 B = B';
%                 
%                 % Plot beamlet intensities
%                 subplot(2,2,i)
%                 imagesc(B), colormap gray
%                 set(gca,'YDir','normal','XTick',[],'YTick',[])
%                 caxis([0 max(f.x)])
%                 axis square
%             end
%             
%             % Positioning
%             h = gcf;
%             pos = h.Position;
%             h.Position = [pos(1) pos(2) pos(3) pos(3)];
%             a = subplot(2,2,1);
%             a.Position = [0.1 0.5 0.3 0.3];
%             b = subplot(2,2,2);
%             b.Position = [0.45 0.5 0.3 0.3];
%             c = subplot(2,2,3);
%             c.Position = [0.1 0.15 0.3 0.3];
%             d = subplot(2,2,4);
%             d.Position = [0.45 0.15 0.3 0.3];
%             
%             % Colorbar
%             e = colorbar('southoutside','Ticks',0:1000:3000,'TickLabels',{},'LineWidth',2);
%             e.Position = [0.1    0.077    0.65    0.02700];
%         end
%         
%         % Plot dose at slice 50 (fig 1,5,10,14).
%         function plotDosePaper(f)
%             
%             figure()
%             idx1 = 40:126;
%             idx2 = 23:152;
%             
%             % Get CT slice
%             ct = dicomread('Prostate_Dicom/CT.2.16.840.1.113662.2.12.0.3173.1271873797.276');
%             ct = double(imresize(ct,[184,184]));
%             ct50 = ct(idx1,idx2);
%             ctShift = ct50 - min(ct50(:));
%             ctShiftScale = ctShift/max(ctShift(:));
%             CT50 = repmat(ctShiftScale,[1 1 3]);
%             
%             % Get Dose
%             Dose = reshape(f.D*f.x,184,184,90);
%             Dose50 = Dose(idx1,idx2,50);
%             
%             % Plot CT
%             body50 = f.mask{end}(idx1,idx2,50);
%             imagesc(CT50), hold on
%             
%             % Plot dose
%             imagesc(Dose50,'AlphaData',0.3*(body50~=0))
%             contour(Dose50,0:10:100,'LineWidth',2);
%             
%             % Plot organ contours
%             for i = 1:length(f.mask)-1
%                contour(f.mask{i}(idx1,idx2,50),1,'k','LineWidth',2); 
%             end
%             
%             % Annotations
%             caxis([min(Dose50(:)) max(Dose50(:))]);
%             axis equal
%             axis off
%             
%             % Colorbar
%             colorbar('southoutside','Ticks',0:20:100,'TickLabels',{},'LineWidth',2)
%         end
        end
    end
end
